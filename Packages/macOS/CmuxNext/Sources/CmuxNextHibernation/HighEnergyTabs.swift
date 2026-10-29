package import CmuxNextWakeups

/// Which hidden tabs use high energy, Chrome's CPU rule for its performance detection
/// (`CpuHealthTracker`, chrome/browser/performance_manager/user_tuning/cpu_health_tracker.cc, which feeds
/// `PerformanceDetectionManager`, chrome/browser/performance_manager/public/user_tuning/performance_detection_manager.h):
/// a tab counts when its renderers used more than ``threshold`` of one core over a whole window, and only a tab
/// nobody sees can count, as Chrome acts only on background tabs. A window here is at least ``window`` long and
/// covers one hide: the tab keeps the same lifecycle generation from the window's first reading to its last.
///
/// Pure: it arms no timer and reads nothing. Each natural wake hands it the hidden tabs (``wake(hidden:now:)``), and
/// it asks for a reading when a hidden tab has no window yet or has one ``window`` old, at most once per ``spacing``.
/// A tab's part of a renderer is the renderer's CPU since the window began, split evenly between the tabs the renderer
/// serves now, as Chrome's `CPUMeasurementMonitor` splits a process's CPU between its frames
/// (components/performance_manager/resource_attribution/cpu_measurement_monitor.cc).
package nonisolated struct HighEnergyTabs: Sendable {
    /// A reading to take: each hidden tab to read with its hide (lifecycle generation), when it was asked for, and
    /// the generation ``land(_:generation:)`` checks.
    package struct Request: Sendable, Equatable {
        package var hides: [String: UInt64]
        package var at: ContinuousClock.Instant
        package var generation: UInt64

        package var keys: [String] { hides.keys.sorted() }
    }

    /// One hidden tab's last whole window: the hide it measured, the tab's share of one core over it, and when it ended.
    package struct Measured: Sendable, Equatable {
        package var hide: UInt64
        package var share: Double
        package var end: ContinuousClock.Instant
    }

    /// One hidden tab's open window: the hide it measures, when it began, and each renderer's CPU time then.
    private struct Window: Sendable {
        var hide: UInt64
        var since: ContinuousClock.Instant
        var cpu: [ProcessUsage.Renderer: Duration]
    }

    /// A hidden tab above this share of one core uses high energy (5 %).
    package static let threshold = 0.05
    /// The shortest window a share is measured over.
    package static let window: Duration = .seconds(60)
    /// The least time between two readings, so a burst of wakes (tabs hidden one after another) reads once.
    package static let spacing: Duration = .seconds(10)

    /// Each hidden tab's last whole window.
    package private(set) var measured: [String: Measured] = [:]
    package private(set) var lastReadingAt: ContinuousClock.Instant?
    private var windows: [String: Window] = [:]
    /// The reading asked for and not landed yet.
    private var measuring: Request?
    private var generation: UInt64 = 0

    package init() {}

    /// A reading was asked for and has not landed.
    package var isMeasuring: Bool { measuring != nil }

    /// A natural wake: `hidden` is every hidden tab with its lifecycle generation. A tab that showed or hid again
    /// since its window began loses the window and its share. Returns the reading to take now, if any.
    package mutating func wake(hidden: [String: UInt64], now: ContinuousClock.Instant) -> Request? {
        windows = windows.filter { hidden[$0.key] == $0.value.hide }
        measured = measured.filter { hidden[$0.key] == $0.value.hide }
        // A reading that never came back (its work was refused at shutdown) does not hold every later one.
        if let asked = measuring, now - asked.at >= Self.window { measuring = nil }
        guard measuring == nil, lastReadingAt.map({ now - $0 >= Self.spacing }) ?? true,
              hidden.contains(where: { entry in windows[entry.key].map { now - $0.since >= Self.window } ?? true })
        else { return nil }
        generation &+= 1
        let request = Request(hides: hidden, at: now, generation: generation)
        measuring = request
        return request
    }

    /// Takes the reading of request `generation`: a tab whose window is ``window`` old or more gets its share and a
    /// new window; a tab with no window, or a new hide, starts one. A renderer first met inside a window counts from
    /// that reading, and one whose time went back (a new process on its id) adds nothing.
    /// - Returns: False when the reading no longer applies (a newer one was asked for): nothing changed.
    @discardableResult
    package mutating func land(_ reading: SaverCPUFreeze.Reading, generation: UInt64) -> Bool {
        guard let request = measuring, request.generation == generation else { return false }
        measuring = nil
        lastReadingAt = reading.at
        var served: [String: [SaverCPUFreeze.Reading.Renderer]] = [:]
        for renderer in reading.renderers {
            for tab in renderer.tabs where request.hides[tab] != nil { served[tab, default: []].append(renderer) }
        }
        for (key, hide) in request.hides {
            let renderers = served[key] ?? []
            let cpu = Dictionary(renderers.map { ($0.id, $0.cpu) }) { first, _ in first }
            guard var open = windows[key], open.hide == hide else {
                windows[key] = Window(hide: hide, since: reading.at, cpu: cpu)
                continue
            }
            let span = reading.at - open.since
            guard span >= Self.window else {
                open.cpu.merge(cpu) { kept, _ in kept }
                windows[key] = open
                continue
            }
            let share = renderers.reduce(0.0) { sum, renderer in
                guard let before = open.cpu[renderer.id], renderer.cpu >= before else { return sum }
                return sum + (renderer.cpu - before) / span / Double(renderer.tabs.count)
            }
            measured[key] = Measured(hide: hide, share: share, end: reading.at)
            windows[key] = Window(hide: hide, since: reading.at, cpu: cpu)
        }
        return true
    }

    /// Tab `key`, hidden now at lifecycle generation `hide` (nil while it shows), used more than ``threshold`` of one
    /// core over its last whole window in this hide, and that window ended less than ``window`` before `now`. An older
    /// share says nothing about the tab now (it may have gone idle since); a wake then asks for a fresh reading.
    package func isHighEnergy(_ key: String, hide: UInt64?, now: ContinuousClock.Instant) -> Bool {
        guard let hide, let last = measured[key], last.hide == hide, now - last.end < Self.window else { return false }
        return last.share > Self.threshold
    }
}

/// The app's side of ``HighEnergyTabs`` (feature `highEnergyTabs`). It has no timer: the browser
/// hibernation's replans (a tab hides or shows, a deadline, a pressure change) and a tab card's question are its
/// wakes. A reading of the hidden tabs' renderers goes through `measure` (off the main actor; it lands on it); a card
/// that asked while it was out refreshes then. Discard is the App's (the person's Hibernate Tab).
@MainActor
package final class HighEnergyTabMonitor {
    package private(set) var rule = HighEnergyTabs()
    /// The hidden browser tabs now, each with its lifecycle generation.
    private let hidden: @MainActor () -> [String: UInt64]
    /// Reads the hidden tabs' renderers (a seam: tests and the `high-energy-tab` capture scene read fixtures).
    package var measure: SaverCPUFreeze.Measure
    private let discardTab: @MainActor (String) -> Void
    /// The clock of the windows (a seam for tests).
    package var now: @MainActor () -> ContinuousClock.Instant = { .now }
    /// Each card that asked while a reading was out, by tab: it refreshes when the reading lands.
    private var waiting: [String: @MainActor () -> Void] = [:]

    package init(measure: @escaping SaverCPUFreeze.Measure, hidden: @escaping @MainActor () -> [String: UInt64],
                 discard: @escaping @MainActor (String) -> Void) {
        self.measure = measure
        self.hidden = hidden
        discardTab = discard
    }

    /// The browser hibernation's replan: a natural wake.
    package func wake() { wake(hidden: hidden(), now: now()) }

    /// Whether tab `key` is hidden and used high energy over its last whole window. Asking is a natural wake (a card
    /// opening or refreshing): when it starts a reading, or one is out, `changed` runs once that reading lands.
    package func usesHighEnergy(_ key: String, changed: @escaping @MainActor () -> Void) -> Bool {
        let hidden = hidden(), now = now()
        wake(hidden: hidden, now: now)
        let hide = hidden[key]
        if hide != nil, rule.isMeasuring { waiting[key] = changed }
        return rule.isHighEnergy(key, hide: hide, now: now)
    }

    /// The person's Discard for tab `key`.
    package func discard(_ key: String) { discardTab(key) }

    private func wake(hidden: [String: UInt64], now: ContinuousClock.Instant) {
        guard let request = rule.wake(hidden: hidden, now: now) else { return }
        measure(request.keys) { [weak self] reading in self?.land(reading, generation: request.generation) }
    }

    private func land(_ reading: SaverCPUFreeze.Reading, generation: UInt64) {
        guard rule.land(reading, generation: generation) else { return }
        let cards = waiting
        waiting.removeAll()
        for changed in cards.values { changed() }
    }
}

nonisolated extension SaverCPUFreeze {
    /// Reads the renderers that serve the given tabs off the main actor and hands the reading back on it.
    package typealias Measure = ([String], @escaping @MainActor @Sendable (Reading) -> Void) -> Void

    /// The one renderer CPU reading of the hidden-page rules (this early freeze and ``HighEnergyTabs``): `sample` (the
    /// tab renderers' processes) runs on `work`'s system lane, the reading of the given tabs from `tabs`, and it
    /// replies in a background-class task of `mainWork` as `owner`.
    package static func measure(owner: String, work: BackgroundWork, mainWork: MainWorkScheduler, tabs: TabRendererDirectory,
                                sample: @escaping @Sendable () -> [(renderer: ProcessUsage.Renderer, usage: ProcessUsage)]) -> Measure {
        { keys, landed in
            work.run(.bestEffort, mayBlock: .system) { SaverCPUFreeze.reading(of: Set(keys), tabs: tabs.snapshot(), renderers: sample()) }
                .reply(on: mainWork, class: .background, owner: owner, landed)
        }
    }
}

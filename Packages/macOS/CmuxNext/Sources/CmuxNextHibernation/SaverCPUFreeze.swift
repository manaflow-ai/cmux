package import CmuxNextWakeups

/// Energy Saver's CPU rule for hidden pages, Chrome's `FreezingPolicy` under battery saver
/// (components/performance_manager/freezing/freezing_policy.cc): in the saver, a hidden page whose renderers used at
/// least ``highProportion`` of one core over its last reading window counts as past the freeze grace, so the freeze
/// plan takes it at once; every other hidden page keeps `browser.freezeHiddenTabs`. The freeze plan's exemptions and
/// the freeze probe (media, Web Audio, capture, WebRTC, devices) still keep any page, as Chrome's `CannotFreezeReason`s
/// do. Out of the saver it asks for no reading and changes nothing.
///
/// Pure: it arms no timer and reads nothing. A plan in the saver asks for a reading when the last one is at least
/// ``window`` old (a hide's plan asks for the first, the page's baseline); the caller reads the renderers off the main
/// actor, hands the reading to ``land(_:generation:)`` and plans again, so a page busy at the hide freezes at the first
/// plan the app makes anyway ``window`` or more later, never later than the grace.
///
/// A page's share is its renderers' CPU between two readings, as Chrome's `CPUMeasurementMonitor` measures
/// (components/performance_manager/resource_attribution/cpu_measurement_monitor.cc): each renderer's delta since its
/// previous reading, split evenly between the tabs it serves now. A renderer read for the first time counts from that
/// reading, and a page counts only when it stayed hidden from the reading before to the one after.
package nonisolated struct SaverCPUFreeze: Sendable {
    /// One reading: the renderers that serve a read page, and when they were read.
    package struct Reading: Sendable {
        /// One renderer: its CPU time so far and every tab it serves now (shown tabs too, which take their part).
        package struct Renderer: Sendable {
            package var id: ProcessUsage.Renderer
            package var cpu: Duration
            package var tabs: [String]

            package init(id: ProcessUsage.Renderer, cpu: Duration, tabs: [String]) {
                self.id = id
                self.cpu = cpu
                self.tabs = tabs
            }
        }

        package var renderers: [Renderer]
        package var at: ContinuousClock.Instant

        package init(renderers: [Renderer], at: ContinuousClock.Instant) {
            self.renderers = renderers
            self.at = at
        }
    }

    /// A reading the caller is to take: the pages to read, when each last hid, and the generation
    /// ``land(_:generation:)`` checks.
    package struct Request: Sendable, Equatable {
        package var keys: [String]
        package var hiddenSince: [String: ContinuousClock.Instant]
        package var generation: UInt64
    }

    /// Chrome's `kFreezingHighCPUProportion` (components/performance_manager/public/features.cc): 25 % of one core.
    package static let highProportion = 0.25
    /// The shortest span between two readings, so a load burst right after the hide is not taken for the page's level.
    package static let window: Duration = .seconds(10)

    /// Each hidden page's CPU share of one core between its last two readings.
    package private(set) var proportions: [String: Double] = [:]
    package private(set) var lastReadingAt: ContinuousClock.Instant?
    /// Each renderer's CPU time at ``lastReadingAt``.
    private var baseline: [ProcessUsage.Renderer: Duration] = [:]
    /// When each page of the last reading had last hid, as its request saw it.
    private var hiddenSince: [String: ContinuousClock.Instant] = [:]
    /// The reading asked for and not landed yet.
    private var measuring: Request?
    private var generation: UInt64 = 0

    package init() {}

    /// `candidates` (hidden pages that may freeze), each busy at ``highProportion`` or more counted as hidden past the
    /// freeze grace, and the reading to take now, if any. Out of the saver it drops every reading and returns them as
    /// they are.
    package mutating func pastGrace(_ candidates: [HibernationPlanner.Candidate], saver: Bool,
                                    now: ContinuousClock.Instant) -> (candidates: [HibernationPlanner.Candidate], read: Request?) {
        guard saver else {
            self = SaverCPUFreeze(generation: generation)
            return (candidates, nil)
        }
        let hides = candidates.map { (key: $0.key, at: now - .seconds($0.hiddenFor)) }
        for hide in hides {
            // Shown since its last request, even while that reading was out: its share counts time it showed. The last
            // reading is still its baseline when it came after the new hide.
            if let read = hiddenSince[hide.key], !Self.sameHide(read, hide.at) {
                hiddenSince[hide.key] = lastReadingAt.flatMap { $0 > hide.at + .milliseconds(1) ? hide.at : nil }
                proportions[hide.key] = nil
            }
        }
        var read: Request?
        if !candidates.isEmpty, measuring == nil, lastReadingAt.map({ now - $0 >= Self.window }) ?? true {
            generation &+= 1
            read = Request(keys: hides.map { $0.key }, hiddenSince: Dictionary(hides.map { ($0.key, $0.at) }) { first, _ in first },
                           generation: generation)
            measuring = read
        }
        let planned = candidates.map { candidate in
            var busy = candidate
            if (proportions[candidate.key] ?? 0) >= Self.highProportion { busy.hiddenFor = .infinity }
            return busy
        }
        return (planned, read)
    }

    /// Takes the reading of request `generation`: each renderer read before adds its delta since then, split between
    /// the tabs it serves now, to each read page hidden since that reading; every renderer read now is the next
    /// window's baseline. A renderer whose time went back (a new process on its id) adds nothing.
    /// - Returns: False when the reading no longer applies (the saver ended, or a newer one was asked for): nothing changed.
    @discardableResult
    package mutating func land(_ reading: Reading, generation: UInt64) -> Bool {
        guard let request = measuring, request.generation == generation else { return false }
        measuring = nil
        var next: [String: Double] = [:]
        if let since = lastReadingAt, reading.at > since {
            let span = reading.at - since
            let stayedHidden = Set(request.keys.filter { key in
                guard let before = hiddenSince[key], let now = request.hiddenSince[key] else { return false }
                return Self.sameHide(before, now)
            })
            for renderer in reading.renderers where !renderer.tabs.isEmpty {
                guard let before = baseline[renderer.id], renderer.cpu >= before else { continue }
                let share = (renderer.cpu - before) / span / Double(renderer.tabs.count)
                for tab in renderer.tabs where stayedHidden.contains(tab) { next[tab, default: 0] += share }
            }
        }
        proportions = next
        baseline = Dictionary(reading.renderers.map { ($0.id, $0.cpu) }) { first, _ in first }
        hiddenSince = request.hiddenSince
        lastReadingAt = reading.at
        return true
    }

    private init(generation: UInt64) {
        self.generation = generation
    }

    /// Two hide instants of one page are the same hide (they come back from seconds hidden, so they differ by rounding).
    private static func sameHide(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Bool {
        (a < b ? b - a : a - b) <= .milliseconds(1)
    }

    /// The reading of `keys` from the tabs' renderers (`tabs`) and the sampled renderer processes (`renderers`): each
    /// renderer that serves one of `keys`, with every tab it serves.
    package static func reading(of keys: Set<String>, tabs: [ProcessUsage.TabRenderers],
                                renderers: [(renderer: ProcessUsage.Renderer, usage: ProcessUsage)],
                                at: ContinuousClock.Instant = .now) -> Reading {
        Reading(renderers: renderers.compactMap { sample -> Reading.Renderer? in
            let served = ProcessUsage.tabs(tabs, servedBy: sample.renderer).map(\.tab)
            guard served.contains(where: { keys.contains($0) }) else { return nil }
            return Reading.Renderer(id: sample.renderer, cpu: .nanoseconds(Int64(clamping: sample.usage.cpuNanos)), tabs: served)
        }, at: at)
    }
}

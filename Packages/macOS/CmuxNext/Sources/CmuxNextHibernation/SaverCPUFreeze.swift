package import CmuxNextWakeups

/// Energy Saver's CPU rule for hidden pages (p14-energy-039), Chrome's `FreezingPolicy` under battery saver
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
package nonisolated struct SaverCPUFreeze: Sendable {
    /// One reading: each read page's renderer CPU time so far, and when it was read.
    package struct Reading: Sendable {
        package var cpu: [String: Duration]
        package var at: ContinuousClock.Instant

        package init(cpu: [String: Duration], at: ContinuousClock.Instant) {
            self.cpu = cpu
            self.at = at
        }
    }

    /// A reading the caller is to take: the pages to read, and the generation ``land(_:generation:)`` checks.
    package struct Request: Sendable, Equatable {
        package var keys: [String]
        package var generation: UInt64
    }

    /// Chrome's `kFreezingHighCPUProportion` (components/performance_manager/public/features.cc): 25 % of one core.
    package static let highProportion = 0.25
    /// The shortest span between two readings, so a load burst right after the hide is not taken for the page's level.
    package static let window: Duration = .seconds(10)

    /// Each hidden page's CPU share of one core between its last two readings.
    package private(set) var proportions: [String: Double] = [:]
    package private(set) var lastReadingAt: ContinuousClock.Instant?
    private var baseline: [String: (cpu: Duration, at: ContinuousClock.Instant)] = [:]
    /// The reading asked for and not landed yet.
    private var measuring: UInt64?
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
        for candidate in candidates {
            // A reading from before the page last hid counts time it showed: its window starts again.
            if let before = baseline[candidate.key], before.at < now - .seconds(candidate.hiddenFor) - .milliseconds(1) {
                baseline[candidate.key] = nil
                proportions[candidate.key] = nil
            }
        }
        var read: Request?
        if !candidates.isEmpty, measuring == nil, lastReadingAt.map({ now - $0 >= Self.window }) ?? true {
            generation &+= 1
            measuring = generation
            read = Request(keys: candidates.map(\.key), generation: generation)
        }
        let planned = candidates.map { candidate in
            var busy = candidate
            if (proportions[candidate.key] ?? 0) >= Self.highProportion { busy.hiddenFor = .infinity }
            return busy
        }
        return (planned, read)
    }

    /// Takes the reading of request `generation`: each page read before gets its share since then, and every page
    /// read now is the next window's baseline. A page whose time went back (a renderer it shared left) gets no share.
    /// - Returns: False when the reading no longer applies (the saver ended, or a newer one was asked for): nothing changed.
    @discardableResult
    package mutating func land(_ reading: Reading, generation: UInt64) -> Bool {
        guard measuring == generation else { return false }
        measuring = nil
        var next: [String: Double] = [:]
        for (key, cpu) in reading.cpu {
            guard let before = baseline[key], reading.at > before.at, cpu >= before.cpu else { continue }
            next[key] = (cpu - before.cpu) / (reading.at - before.at)
        }
        proportions = next
        baseline = reading.cpu.mapValues { (cpu: $0, at: reading.at) }
        lastReadingAt = reading.at
        return true
    }

    private init(generation: UInt64) {
        self.generation = generation
    }

    /// The reading of `keys` from the tabs' renderers (`tabs`) and the sampled renderer processes (`renderers`).
    package static func reading(of keys: Set<String>, tabs: [ProcessUsage.TabRenderers],
                                renderers: [(renderer: ProcessUsage.Renderer, usage: ProcessUsage)]) -> Reading {
        Reading(cpu: cpuTime(ProcessUsage.perTab(tabs, renderers: renderers)).filter { keys.contains($0.key) }, at: .now)
    }

    /// Each tab's CPU time: a renderer several tabs share is split evenly between them, as Chrome's resource
    /// attribution splits a process's CPU between its frames (components/performance_manager/resource_attribution/
    /// cpu_measurement_monitor.cc), so a hidden page is not charged in full for a shown page of the same site.
    package static func cpuTime(_ usage: [ProcessUsage.TabUsage]) -> [String: Duration] {
        var cpu: [String: Duration] = [:]
        for tab in usage {
            let nanos = tab.renderers.reduce(0.0) { $0 + Double($1.usage.cpuNanos) / Double(max($1.tabs.count, 1)) }
            cpu[tab.tab] = .nanoseconds(Int64(nanos.rounded()))
        }
        return cpu
    }
}

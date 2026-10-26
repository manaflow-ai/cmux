public import CmuxNextCompat
import Foundation

/// One bucketed histogram: a count per bucket, the sample count and their sum, nothing else (no
/// sample is kept). Recording is O(1): the layout has a fixed number of buckets, searched by
/// bisection. The analog of Chrome's `base::Histogram` (`base/metrics/histogram.cc`), whose
/// exponential layout ``Layout/exponential(minimum:maximum:bucketCount:)`` copies
/// (`Histogram::InitializeBucketRanges`), and of its linear one (`LinearHistogram`).
///
/// It is local only: `debug.memory` shows it and nothing uploads it (p07-memory.md section 3.G:
/// field upload is deferred until after the push).
public nonisolated struct MemoryHistogram: Sendable, Equatable, Encodable {
    /// The buckets' lower bounds, ascending and starting at 0; the last bucket has no upper bound.
    public nonisolated struct Layout: Sendable, Equatable {
        public let lowerBounds: [Int]

        /// Chrome's exponential layout: bucket 0 is [0, `minimum`), the last one is [`maximum`, ∞),
        /// and the ones between grow by an equal ratio, each at least 1 wide.
        ///
        /// - Parameters:
        ///   - minimum: The second bucket's lower bound; at least 1.
        ///   - maximum: The last bucket's lower bound; above `minimum`.
        ///   - bucketCount: Buckets, the two open ones included; at least 3.
        public static func exponential(minimum: Int, maximum: Int, bucketCount: Int) -> Layout {
            let minimum = max(minimum, 1)
            let maximum = max(maximum, minimum + 1)
            let bucketCount = max(bucketCount, 3)
            var bounds = [0, minimum]
            bounds.reserveCapacity(bucketCount)
            let logMaximum = log(Double(maximum))
            var current = minimum
            for index in 2 ..< bucketCount {
                let logCurrent = log(Double(current))
                let logNext = logCurrent + (logMaximum - logCurrent) / Double(bucketCount - index)
                let next = Int(exp(logNext).rounded())
                current = next > current ? next : current + 1
                bounds.append(current)
            }
            return Layout(lowerBounds: bounds)
        }

        /// Buckets `width` wide from 0, the last one [`maximum`, ∞).
        public static func linear(width: Int, maximum: Int) -> Layout {
            let width = max(width, 1)
            return Layout(lowerBounds: Array(stride(from: 0, through: max(maximum, width), by: width)))
        }

        /// Process footprints in MiB: Chrome's `UMA_HISTOGRAM_MEMORY_LARGE_MB` (1 to 64,000, 100 buckets).
        public static let footprintMiB = exponential(minimum: 1, maximum: 64_000, bucketCount: 100)
        /// Latencies in milliseconds: Chrome's `UMA_HISTOGRAM_MEDIUM_TIMES` range (to 3 minutes, 50 buckets).
        public static let milliseconds = exponential(minimum: 1, maximum: 180_000, bucketCount: 50)
        /// Events per hour: Chrome's `UMA_HISTOGRAM_COUNTS_1000`.
        public static let perHour = exponential(minimum: 1, maximum: 1_000, bucketCount: 50)
        /// Minutes of one hour, 5 minutes per bucket; the last bucket is the whole hour.
        public static let minutesOfHour = linear(width: 5, maximum: 60)

        /// The bucket `value` falls in; a negative value is in bucket 0.
        public func bucket(of value: Int) -> Int {
            var low = 0
            var high = lowerBounds.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lowerBounds[middle] <= value { low = middle } else { high = middle - 1 }
            }
            return low
        }
    }

    /// One non-empty bucket as `debug.memory` writes it.
    public nonisolated struct Bucket: Sendable, Equatable, Encodable {
        public let min: Int
        /// The next bucket's lower bound; nil for the last bucket.
        public let max: Int?
        public let count: Int

        public init(min: Int, max: Int?, count: Int) {
            self.min = min
            self.max = max
            self.count = count
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(min, forKey: .min)
            if let max { try container.encode(max, forKey: .max) } else { try container.encodeNil(forKey: .max) }
            try container.encode(count, forKey: .count)
        }

        enum CodingKeys: String, CodingKey { case min, max, count }
    }

    public let layout: Layout
    /// The samples in each bucket, one entry per ``Layout/lowerBounds`` entry.
    public private(set) var counts: [Int]
    /// The samples recorded.
    public private(set) var count = 0
    /// The sum of the samples recorded (negative ones as 0).
    public private(set) var sum = 0

    public init(layout: Layout) {
        self.layout = layout
        counts = Array(repeating: 0, count: layout.lowerBounds.count)
    }

    /// Records `value` `times` times (a run of equal samples, such as hours with no event, in one step).
    public mutating func record(_ value: Int, times: Int = 1) {
        guard times > 0 else { return }
        let value = max(value, 0)
        counts[layout.bucket(of: value)] += times
        count += times
        sum += value * times
    }

    /// The buckets that hold a sample, lowest first.
    public var buckets: [Bucket] {
        counts.indices.compactMap { index in
            guard counts[index] > 0 else { return nil }
            let next = index + 1 < layout.lowerBounds.count ? layout.lowerBounds[index + 1] : nil
            return Bucket(min: layout.lowerBounds[index], max: next, count: counts[index])
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(sum, forKey: .sum)
        try container.encode(buckets, forKey: .buckets)
    }

    enum CodingKeys: String, CodingKey { case count, sum, buckets }
}

/// The app's local memory histograms for `debug.memory`'s `histograms`: the app's and the
/// renderers' footprints, discards per hour by content kind, wake latency, minutes per hour at the
/// warning and critical levels, and the kernel's WARN events per hour. Local only, with no network
/// code: Chrome uploads the same numbers as UMA (`process_memory_metrics_emitter.cc`,
/// `components/memory_pressure/memory_pressure_level_reporter.cc`), cmux keeps them until field
/// upload lands after the push.
///
/// Event-driven, as ``MemoryPressureHistory``: it records what the pressure source delivers, what the
/// override sets and what its owners report, and no timer runs here. An hour ends when the next event or
/// read finds the clock past it; it then records that hour and any empty hours since in one step
/// each, so a read changes no count. The clock is suspend-aware (Chrome's `LiveTicks`, as Memory
/// Saver's timers): hours while the Mac sleeps are not hours. Footprints come from the owner's
/// periodic sampler through ``recordFootprints(_:)``, never from a pressure change or a read.
@MainActor
public final class MemoryHistograms {
    /// One histogram hour.
    public nonisolated static let hour: Duration = .seconds(3_600)

    /// The histograms as `debug.memory` copies them: only completed hours are in the per-hour ones.
    public nonisolated struct Snapshot: Sendable, Equatable, Encodable {
        /// Completed hours since the histograms started.
        public var hours: Int
        public var appFootprintMiB: MemoryHistogram
        /// The sum of the Chromium renderers' and WebKit WebContent processes' footprints per sample.
        public var rendererFootprintMiB: MemoryHistogram
        /// From a hibernated page's wake to its page being back.
        public var wakeMilliseconds: MemoryHistogram
        /// One histogram per content kind.
        public var discardsPerHour: [String: MemoryHistogram]
        public var warningMinutesPerHour: MemoryHistogram
        public var criticalMinutesPerHour: MemoryHistogram
        public var warnEventsPerHour: MemoryHistogram

        /// No samples.
        public static let empty = Snapshot(discardKinds: [])

        init(discardKinds: [String]) {
            hours = 0
            appFootprintMiB = MemoryHistogram(layout: .footprintMiB)
            rendererFootprintMiB = MemoryHistogram(layout: .footprintMiB)
            wakeMilliseconds = MemoryHistogram(layout: .milliseconds)
            discardsPerHour = Dictionary(discardKinds.map { ($0, MemoryHistogram(layout: .perHour)) }, uniquingKeysWith: { first, _ in first })
            warningMinutesPerHour = MemoryHistogram(layout: .minutesOfHour)
            criticalMinutesPerHour = MemoryHistogram(layout: .minutesOfHour)
            warnEventsPerHour = MemoryHistogram(layout: .perHour)
        }

        enum CodingKeys: String, CodingKey {
            case hours
            case appFootprintMiB = "app_pmf_mb"
            case rendererFootprintMiB = "renderer_pmf_mb"
            case wakeMilliseconds = "wake_latency_ms"
            case discardsPerHour = "discards_per_hour"
            case warningMinutesPerHour = "warning_minutes_per_hour"
            case criticalMinutesPerHour = "critical_minutes_per_hour"
            case warnEventsPerHour = "warn_events_per_hour"
        }
    }

    private var histograms: Snapshot
    private let elapsed: () -> Duration
    /// The source it follows, kept while it follows it.
    private let pressure: MemoryPressureEvents
    private var observation: MainActorHandlerRegistration<MemoryPressureLevel>?
    private var kernelLevel: MemoryPressureLevel
    private var override: MemoryPressureLevel?
    /// The applied level.
    private var level: MemoryPressureLevel
    /// The open hour, counted from 0.
    private var openHour = 0
    /// Milliseconds since the start up to which the open hour's time at a level is counted.
    private var countedTo = 0
    private var warningMilliseconds = 0
    private var criticalMilliseconds = 0
    private var warnEvents = 0
    private var discards: [String: Int]

    /// Starts with `pressure`'s current level and no override.
    ///
    /// - Parameters:
    ///   - pressure: The app's one memory pressure source.
    ///   - discardKinds: The content kinds whose discards are counted (`ContentKind` raw values); another kind has no histogram.
    ///   - elapsed: Time since the start; the default counts from this init on the suspending clock.
    public init(pressure: MemoryPressureEvents, discardKinds: [String], elapsed: (() -> Duration)? = nil) {
        let start = SuspendingClock.now
        self.elapsed = elapsed ?? { SuspendingClock.now - start }
        self.pressure = pressure
        histograms = Snapshot(discardKinds: discardKinds)
        discards = Dictionary(discardKinds.map { ($0, 0) }, uniquingKeysWith: { first, _ in first })
        kernelLevel = pressure.currentLevel
        level = kernelLevel
        observation = pressure.observe { [weak self] level in self?.kernelDidDeliver(level) }
    }

    /// The histograms now, after closing every hour that has ended.
    public func snapshot() -> Snapshot {
        advance()
        return histograms
    }

    /// Counts one discard of `kind` in the open hour.
    public func recordDiscard(kind: String) {
        advance()
        discards[kind]? += 1
    }

    /// Records one wake's latency.
    public func recordWake(_ latency: Duration) {
        histograms.wakeMilliseconds.record(Self.milliseconds(latency))
    }

    /// Records the app's footprint and the renderers' total, each when at least one of its rows is
    /// known: one periodic sample (O(rows), two bucket records).
    public func recordFootprints(_ processes: MemoryDiagnosticsProcesses) {
        func mebibytes(_ kinds: Set<MemoryDiagnosticsProcesses.Kind>) -> Int? {
            let known = processes.rows.filter { kinds.contains($0.kind) }.compactMap(\.physFootprintBytes)
            return known.isEmpty ? nil : known.reduce(0, +) >> 20
        }
        if let app = mebibytes([.app]) { histograms.appFootprintMiB.record(app) }
        if let renderers = mebibytes([.chromiumRenderer, .webkitWebContent]) { histograms.rendererFootprintMiB.record(renderers) }
    }

    /// Records that the debug override is now `override` (nil: cleared), as the coordinator holds it.
    public func overrideDidChange(_ override: MemoryPressureLevel?) {
        guard override != self.override else { return }
        self.override = override
        apply()
    }

    private func kernelDidDeliver(_ delivered: MemoryPressureLevel) {
        advance()
        if delivered == .warning { warnEvents += 1 }
        guard delivered != kernelLevel else { return }
        kernelLevel = delivered
        apply()
    }

    /// Counts the time at the old applied level, then takes the new one.
    private func apply() {
        advance()
        level = override ?? kernelLevel
    }

    /// Counts the open hour's time at the applied level up to now, and closes the open hour and the
    /// empty hours after it once now is past them (two records per histogram at most).
    private func advance() {
        let hourMilliseconds = Self.milliseconds(Self.hour)
        let now = max(Self.milliseconds(elapsed()), countedTo)
        let nowHour = now / hourMilliseconds
        guard nowHour > openHour else { return count(to: now) }
        count(to: (openHour + 1) * hourMilliseconds)
        closeHour(
            discards: discards, warnEvents: warnEvents,
            warningMinutes: Self.minutes(warningMilliseconds), criticalMinutes: Self.minutes(criticalMilliseconds), times: 1)
        let empty = nowHour - openHour - 1
        closeHour(
            discards: discards.mapValues { _ in 0 }, warnEvents: 0,
            warningMinutes: level == .warning ? 60 : 0, criticalMinutes: level == .critical ? 60 : 0, times: empty)
        openHour = nowHour
        countedTo = nowHour * hourMilliseconds
        warningMilliseconds = 0
        criticalMilliseconds = 0
        warnEvents = 0
        for kind in discards.keys { discards[kind] = 0 }
        count(to: now)
    }

    private func count(to now: Int) {
        let span = now - countedTo
        countedTo = now
        switch level {
        case .warning: warningMilliseconds += span
        case .critical: criticalMilliseconds += span
        case .normal: break
        }
    }

    private func closeHour(discards: [String: Int], warnEvents: Int, warningMinutes: Int, criticalMinutes: Int, times: Int) {
        guard times > 0 else { return }
        histograms.hours += times
        for (kind, count) in discards { histograms.discardsPerHour[kind]?.record(count, times: times) }
        histograms.warnEventsPerHour.record(warnEvents, times: times)
        histograms.warningMinutesPerHour.record(warningMinutes, times: times)
        histograms.criticalMinutesPerHour.record(criticalMinutes, times: times)
    }

    private nonisolated static func minutes(_ milliseconds: Int) -> Int {
        min((milliseconds + 30_000) / 60_000, 60)
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

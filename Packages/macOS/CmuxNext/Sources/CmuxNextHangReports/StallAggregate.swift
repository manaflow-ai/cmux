/// The collector's findings since the last report: the watchdog's histogram of finished stalls,
/// the stacks of the longest ones and the blocking detector's new call sites (already reduced to
/// ``HangReportFrame``s, so the aggregate can be saved and sent after a relaunch), and the launches
/// (``LaunchAggregate``), which ride the same pending file, drain and merge.
public nonisolated struct StallAggregate: Codable, Sendable, Equatable {
    /// Histogram edges in milliseconds: buckets are `[50, 100)`, `[100, 250)`, ...,
    /// `[10000, one day)`.
    public static let bucketEdgesMs = [50, 100, 250, 500, 1_000, 2_000, 5_000, 10_000]
    /// The shortest stall whose stack is kept.
    public static let sampledStallMs = 250
    /// The hang length (the watchdog's `hangThreshold`).
    public static let hangMs = 2_000
    /// The most stall stacks and hang stacks kept per report.
    public static let maxSamples = 8

    /// One count per bucket of ``bucketEdgesMs``.
    public private(set) var counts: [Int] = Array(repeating: 0, count: StallAggregate.bucketEdgesMs.count)
    /// The longest sampled stalls, longest first.
    public private(set) var stalls: [HangSample] = []
    /// The longest hangs, longest first.
    public private(set) var hangs: [HangSample] = []
    /// The launches that reached `startup_complete`.
    public private(set) var launches = LaunchAggregate()
    /// The blocking detector's call sites, first seen first, each once (at most ``maxSamples``).
    public private(set) var blocking: [HangSample] = []

    private enum CodingKeys: String, CodingKey {
        case counts, stalls, hangs, launches, blocking
    }

    /// Makes the value from its parts.
    public init() {}

    /// Decodes a saved aggregate; one saved by a build without launch histograms has no `launches`,
    /// and one saved before blocking samples existed has no `blocking`.
    /// The file is untrusted: `counts` gets one nonnegative count per bucket of ``bucketEdgesMs``
    /// (missing ones are 0, extra ones are dropped), so ``histogram`` and ``merge(_:)`` stay in range.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decode([Int].self, forKey: .counts)
        counts = Self.bucketEdgesMs.indices.map { $0 < saved.count ? max(0, saved[$0]) : 0 }
        stalls = try container.decode([HangSample].self, forKey: .stalls)
        hangs = try container.decode([HangSample].self, forKey: .hangs)
        launches = try container.decodeIfPresent(LaunchAggregate.self, forKey: .launches) ?? LaunchAggregate()
        blocking = try container.decodeIfPresent([HangSample].self, forKey: .blocking) ?? []
    }

    /// Whether nothing was recorded.
    public var isEmpty: Bool { isEmptyWithoutLaunches && launches.isEmpty && blocking.isEmpty }

    /// Whether no stall or hang was recorded (launches and blocking samples aside: a schema-2 report
    /// carries neither).
    public var isEmptyWithoutLaunches: Bool { counts.allSatisfy { $0 == 0 } && stalls.isEmpty && hangs.isEmpty }

    /// Counts one launch at its `startup_complete`.
    public mutating func record(launch: LaunchAggregate.Record) {
        launches.record(launch)
    }

    /// Counts a finished stall of `durationMs`.
    public mutating func count(durationMs: Int) {
        guard let index = Self.bucketIndex(durationMs) else { return }
        counts[index] = counts[index].saturatingAdding(1)
    }

    /// Whether a stall of `durationMs` would get a stack slot (so the caller resolves its stack).
    public func wantsStallSample(durationMs: Int) -> Bool {
        durationMs >= Self.sampledStallMs && (stalls.count < Self.maxSamples || durationMs > (stalls.last?.durationMs ?? 0))
    }

    /// Whether a hang of `durationMs` would get a stack slot.
    public func wantsHangSample(durationMs: Int) -> Bool {
        hangs.count < Self.maxSamples || durationMs > (hangs.last?.durationMs ?? 0)
    }

    /// Keeps `sample` when it is among the longest (a stall or a hang by its kind), or, for a blocking
    /// sample, when its site is new and there is room.
    public mutating func keep(_ sample: HangSample) {
        switch sample.kind {
        case .hang: Self.insert(sample, into: &hangs)
        case .stall: Self.insert(sample, into: &stalls)
        case .blocking: keepBlocking(sample)
        }
    }

    /// Adds another aggregate (the one saved by the previous launch).
    public mutating func merge(_ other: StallAggregate) {
        for (index, count) in other.counts.enumerated() where index < counts.count {
            counts[index] = counts[index].saturatingAdding(max(0, count))
        }
        other.stalls.forEach { Self.insert($0, into: &stalls) }
        other.hangs.forEach { Self.insert($0, into: &hangs) }
        launches.merge(other.launches)
        other.blocking.forEach { keepBlocking($0) }
    }

    /// Whether a blocking sample of this site would be kept (it is new and there is room).
    public func wantsBlockingSample(_ sample: HangSample) -> Bool {
        blocking.count < Self.maxSamples && !blocking.contains(sample)
    }

    /// Forgets the blocking samples (a saved aggregate a build without them reads).
    public mutating func dropBlocking() {
        blocking = []
    }

    private mutating func keepBlocking(_ sample: HangSample) {
        guard wantsBlockingSample(sample) else { return }
        blocking.append(sample)
    }

    /// The histogram as report buckets (nonzero only).
    public var histogram: [HistogramBucket] {
        counts.enumerated().compactMap { index, count in
            guard count > 0 else { return nil }
            let high = index + 1 < Self.bucketEdgesMs.count ? Self.bucketEdgesMs[index + 1] : HistogramBucket.maxMs
            return HistogramBucket(lowMs: Self.bucketEdgesMs[index], highMs: high, count: count)
        }
    }

    static func bucketIndex(_ durationMs: Int) -> Int? {
        guard durationMs >= bucketEdgesMs[0] else { return nil }
        return (bucketEdgesMs.lastIndex { durationMs >= $0 })
    }

    private static func insert(_ sample: HangSample, into list: inout [HangSample]) {
        let index = list.firstIndex { $0.durationMs < sample.durationMs } ?? list.endIndex
        list.insert(sample, at: index)
        if list.count > maxSamples { list.removeLast(list.count - maxSamples) }
    }
}

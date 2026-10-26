/// The collector's findings since the last report: the watchdog's histogram of finished stalls and
/// the stacks of the longest ones (already reduced to ``HangReportFrame``s, so the aggregate can be
/// saved and sent after a relaunch), and the launches (``LaunchAggregate``), which ride the same
/// pending file, drain and merge.
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

    private enum CodingKeys: String, CodingKey {
        case counts, stalls, hangs, launches
    }

    /// Makes the value from its parts.
    public init() {}

    /// Decodes a saved aggregate; one saved by a build without launch histograms has no `launches`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        counts = try container.decode([Int].self, forKey: .counts)
        stalls = try container.decode([HangSample].self, forKey: .stalls)
        hangs = try container.decode([HangSample].self, forKey: .hangs)
        launches = try container.decodeIfPresent(LaunchAggregate.self, forKey: .launches) ?? LaunchAggregate()
    }

    /// Whether nothing was recorded.
    public var isEmpty: Bool { counts.allSatisfy { $0 == 0 } && stalls.isEmpty && hangs.isEmpty && launches.isEmpty }

    /// Counts one launch at its `startup_complete`.
    public mutating func record(launch: LaunchAggregate.Record) {
        launches.record(launch)
    }

    /// Counts a finished stall of `durationMs`.
    public mutating func count(durationMs: Int) {
        guard let index = Self.bucketIndex(durationMs) else { return }
        counts[index] += 1
    }

    /// Whether a stall of `durationMs` would get a stack slot (so the caller resolves its stack).
    public func wantsStallSample(durationMs: Int) -> Bool {
        durationMs >= Self.sampledStallMs && (stalls.count < Self.maxSamples || durationMs > (stalls.last?.durationMs ?? 0))
    }

    /// Whether a hang of `durationMs` would get a stack slot.
    public func wantsHangSample(durationMs: Int) -> Bool {
        hangs.count < Self.maxSamples || durationMs > (hangs.last?.durationMs ?? 0)
    }

    /// Keeps `sample` when it is among the longest (a stall or a hang by its kind).
    public mutating func keep(_ sample: HangSample) {
        if sample.kind == .hang { Self.insert(sample, into: &hangs) } else { Self.insert(sample, into: &stalls) }
    }

    /// Adds another aggregate (the one saved by the previous launch).
    public mutating func merge(_ other: StallAggregate) {
        for (index, count) in other.counts.enumerated() where index < counts.count { counts[index] += count }
        other.stalls.forEach { Self.insert($0, into: &stalls) }
        other.hangs.forEach { Self.insert($0, into: &hangs) }
        launches.merge(other.launches)
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

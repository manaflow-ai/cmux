/// The collector's findings since the last report: the watchdog's histogram of finished stalls,
/// the stacks of the longest ones and the blocking detector's new call sites (already reduced to
/// ``HangReportFrame``s, so the aggregate can be saved and sent after a relaunch), the hang watch's longest
/// hangs of other threads (apart from the main thread's, so a lane that hangs again and again never pushes a
/// main-thread hang out), and the launches
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
    /// The most blocking detector call sites kept per report (schema 3's `blocking[]`, p09-observability-089).
    public static let maxBlockingSamples = 32

    /// One count per bucket of ``bucketEdgesMs``.
    public private(set) var counts: [Int] = Array(repeating: 0, count: StallAggregate.bucketEdgesMs.count)
    /// The longest sampled stalls, longest first.
    public private(set) var stalls: [HangSample] = []
    /// The longest hangs, longest first.
    public private(set) var hangs: [HangSample] = []
    /// The longest hangs of watched threads other than the main thread (``HangSample/Source/hangWatch``,
    /// p09-observability-068), longest first: their own ``maxSamples`` slots, as Chrome's `HangWatcher` keeps
    /// each thread type's hangs apart from the UI thread's.
    public private(set) var threadHangs: [HangSample] = []
    /// The launches that reached `startup_complete`.
    public private(set) var launches = LaunchAggregate()
    /// The blocking detector's call sites, first seen first, each once (at most ``maxBlockingSamples``).
    public private(set) var blocking: [HangSample] = []

    private enum CodingKeys: String, CodingKey {
        case counts, stalls, hangs, threadHangs, launches, blocking
    }

    /// Makes the value from its parts.
    public init() {}

    /// Decodes a saved aggregate; one saved by a build without launch histograms has no `launches`,
    /// one saved before blocking samples existed has no `blocking`, and one saved before thread hangs has no `threadHangs`.
    /// The file is untrusted: `counts` gets one nonnegative count per bucket of ``bucketEdgesMs``
    /// (missing ones are 0, extra ones are dropped), so ``histogram`` and ``merge(_:)`` stay in range.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decode([Int].self, forKey: .counts)
        counts = Self.bucketEdgesMs.indices.map { $0 < saved.count ? max(0, saved[$0]) : 0 }
        stalls = try container.decode([HangSample].self, forKey: .stalls)
        hangs = try container.decode([HangSample].self, forKey: .hangs)
        threadHangs = try container.decodeIfPresent([HangSample].self, forKey: .threadHangs) ?? []
        launches = try container.decodeIfPresent(LaunchAggregate.self, forKey: .launches) ?? LaunchAggregate()
        blocking = try container.decodeIfPresent([HangSample].self, forKey: .blocking) ?? []
    }

    /// Whether nothing was recorded.
    public var isEmpty: Bool { isEmptyWithoutLaunches && launches.isEmpty && blocking.isEmpty && threadHangs.isEmpty }

    /// Whether no stall or main-thread hang was recorded (launches, blocking samples and thread hangs aside: a
    /// schema-2 report carries none of them).
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

    /// Whether a main-thread hang of `durationMs` would get a stack slot.
    public func wantsHangSample(durationMs: Int) -> Bool {
        Self.wantsSlot(durationMs, in: hangs)
    }

    /// Whether a watched thread's hang of `durationMs` would get a stack slot.
    public func wantsThreadHangSample(durationMs: Int) -> Bool {
        Self.wantsSlot(durationMs, in: threadHangs)
    }

    /// Keeps `sample` when it is among the longest (a stall, a main-thread hang or a watched thread's hang by its
    /// kind and source), or, for a blocking sample, when its site is new and there is room.
    public mutating func keep(_ sample: HangSample) {
        switch sample.kind {
        case .hang where sample.source == .hangWatch: Self.insert(sample, into: &threadHangs)
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
        other.hangs.forEach { keep($0) }
        other.threadHangs.forEach { keep($0) }
        launches.merge(other.launches)
        other.blocking.forEach { keepBlocking($0) }
    }

    /// Whether a blocking sample of this site would be kept (it is new and there is room).
    public func wantsBlockingSample(_ sample: HangSample) -> Bool {
        blocking.count < Self.maxBlockingSamples && !blocking.contains(sample)
    }

    /// Forgets the blocking samples (a saved aggregate a build without them reads).
    public mutating func dropBlocking() {
        blocking = []
    }

    /// Forgets the watched threads' hangs (a saved aggregate a build whose schema has none reads).
    public mutating func dropThreadHangs() {
        threadHangs = []
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

    private static func wantsSlot(_ durationMs: Int, in list: [HangSample]) -> Bool {
        list.count < maxSamples || durationMs > (list.last?.durationMs ?? 0)
    }

    private static func insert(_ sample: HangSample, into list: inout [HangSample]) {
        let index = list.firstIndex { $0.durationMs < sample.durationMs } ?? list.endIndex
        list.insert(sample, at: index)
        if list.count > maxSamples { list.removeLast(list.count - maxSamples) }
    }
}

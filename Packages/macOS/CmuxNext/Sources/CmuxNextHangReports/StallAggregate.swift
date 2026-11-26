/// The watchdog's findings since the last report: a histogram of finished stalls and the stacks
/// of the longest ones (already reduced to ``HangReportFrame``s, so the aggregate can be saved and sent
/// after a relaunch). Its rules (the buckets, which samples are kept, the merge) are Rust's,
/// asked through ``HangReportRules``; this is the value Swift holds between calls.
public nonisolated struct StallAggregate: Codable, Sendable, Equatable {
    /// One count per histogram bucket (Rust's `BUCKET_EDGES_MS`: `[50, 100)`, ..., `[10000, one day)`).
    public private(set) var counts: [Int] = Array(repeating: 0, count: 8)
    /// The longest sampled stalls, longest first.
    public private(set) var stalls: [HangSample] = []
    /// The longest hangs, longest first.
    public private(set) var hangs: [HangSample] = []

    /// Makes the value from its parts.
    public init() {}

    /// Whether nothing was recorded (true when the rules do not answer: nothing is sent).
    public var isEmpty: Bool { summary?.isEmpty ?? true }

    /// The histogram as report buckets (nonzero only).
    public var histogram: [HistogramBucket] { summary?.histogram ?? [] }

    /// Counts one stall in the bucket `note_stall` named.
    mutating func count(bucket: Int) {
        guard counts.indices.contains(bucket) else { return }
        counts[bucket] += 1
    }

    /// Keeps `sample` when it is among the longest (a stall or a hang by its kind).
    public mutating func keep(_ sample: HangSample) {
        struct Request: Encodable {
            var aggregate: StallAggregate
            var sample: HangSample
        }
        if let kept = HangReportRules.call("keep", Request(aggregate: self, sample: sample), as: HangReportRules.Aggregate.self) {
            self = kept.aggregate
        }
    }

    /// Adds another aggregate (the one saved by the previous launch).
    public mutating func merge(_ other: StallAggregate) {
        struct Request: Encodable {
            var aggregate: StallAggregate
            var other: StallAggregate
        }
        if let merged = HangReportRules.call("merge", Request(aggregate: self, other: other), as: HangReportRules.Aggregate.self) {
            self = merged.aggregate
        }
    }

    private struct Summary: Decodable {
        var isEmpty: Bool
        var histogram: [HistogramBucket]
    }

    private var summary: Summary? {
        HangReportRules.call("aggregate", HangReportRules.Aggregate(aggregate: self), as: Summary.self)
    }
}

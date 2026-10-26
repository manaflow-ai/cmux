/// One histogram bucket in milliseconds: `count` values were at least `lowMs` and below `highMs`.
public nonisolated struct HistogramBucket: Codable, Sendable, Equatable {
    /// The most buckets one histogram carries.
    public static let maxBuckets = 32
    /// The longest duration a bucket edge may name (one day).
    public static let maxMs = 86_400_000

    /// The bucket's lower edge, in milliseconds.
    public var lowMs: Int
    /// The bucket's upper edge, in milliseconds.
    public var highMs: Int
    /// How many values fell in it.
    public var count: Int

    /// Makes the value from its parts.
    public init(lowMs: Int, highMs: Int, count: Int) {
        self.lowMs = min(max(0, lowMs), Self.maxMs)
        self.highMs = min(max(self.lowMs, highMs), Self.maxMs)
        self.count = max(0, count)
    }

    /// `buckets` merged by edges (MetricKit can repeat an edge pair), nonzero only, sorted, capped.
    /// A merged count stops at `Int.max`: a delivery's counts are untrusted.
    public static func normalized(_ buckets: [HistogramBucket]) -> [HistogramBucket] {
        var counts: [Edges: Int] = [:]
        for bucket in buckets where bucket.count > 0 {
            let edges = Edges(low: bucket.lowMs, high: bucket.highMs)
            counts[edges] = (counts[edges] ?? 0).saturatingAdding(bucket.count)
        }
        let sorted = counts.keys.sorted { ($0.low, $0.high) < ($1.low, $1.high) }
        return sorted.prefix(maxBuckets).map { HistogramBucket(lowMs: $0.low, highMs: $0.high, count: counts[$0] ?? 0) }
    }

    /// A bucket's edges, the merge key of ``normalized(_:)``.
    private struct Edges: Hashable {
        let low: Int
        let high: Int
    }
}

extension Int {
    /// `self + other`, or `Int.max` / `Int.min` where the sum would overflow: counts from MetricKit
    /// and from a saved file are untrusted, and an overflowing `+` traps.
    func saturatingAdding(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other > 0 ? .max : .min
    }
}

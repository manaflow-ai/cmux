/// One latency distribution: counts per ``InputLatencyBuckets`` bucket, plus the exact maximum and
/// sum. Percentiles come out of the counts, as a UMA histogram's do (Chromium reads field latency
/// as distributions, never as means): a percentile is the upper edge of the bucket its rank falls
/// in, never above the largest value seen; a rank in the overflow bucket is the largest value.
public struct InputLatencyHistogram: Sendable, Equatable {
    /// The counts per bucket.
    public private(set) var buckets = InputLatencyBuckets()
    /// Values counted.
    public private(set) var count: UInt64 = 0
    /// The largest value, in nanoseconds (0 when empty).
    public private(set) var maxNanos: UInt64 = 0
    /// The sum of the values, in nanoseconds (wraps only after centuries of input).
    public private(set) var sumNanos: UInt64 = 0

    /// An empty histogram.
    public init() {}

    /// Counts one value.
    public mutating func record(nanos: UInt64) {
        buckets.record(nanos: nanos)
        count &+= 1
        maxNanos = max(maxNanos, nanos)
        sumNanos &+= nanos
    }

    /// Adds `other`'s values: the counts per bucket and in total, the sum, and the larger maximum.
    public mutating func add(_ other: InputLatencyHistogram) {
        buckets.add(other.buckets)
        count &+= other.count
        maxNanos = max(maxNanos, other.maxNanos)
        sumNanos &+= other.sumNanos
    }

    /// The value at or below which `fraction` (0...1) of the counted values fall, in nanoseconds,
    /// or nil when the histogram is empty.
    public func percentileNanos(_ fraction: Double) -> UInt64? {
        guard count > 0 else { return nil }
        let clamped = min(max(fraction, 0), 1)
        let rank = max(1, UInt64(exactly: (clamped * Double(count)).rounded(.up)) ?? count)
        var seen: UInt64 = 0
        for (bucket, bucketCount) in buckets.counts.enumerated() {
            seen &+= bucketCount
            guard seen >= rank else { continue }
            guard bucket < InputLatencyBuckets.edgesNanos.count else { return maxNanos }
            return min(InputLatencyBuckets.edgesNanos[bucket], maxNanos)
        }
        return maxNanos
    }

    /// The histogram as report fields.
    public var snapshot: InputLatencyHistogramSnapshot {
        InputLatencyHistogramSnapshot(
            count: count,
            buckets: buckets.counts,
            p50Milliseconds: percentileNanos(0.5).map(Self.milliseconds),
            p95Milliseconds: percentileNanos(0.95).map(Self.milliseconds),
            p99Milliseconds: percentileNanos(0.99).map(Self.milliseconds),
            maxMilliseconds: count > 0 ? Self.milliseconds(maxNanos) : nil
        )
    }

    private static func milliseconds(_ nanos: UInt64) -> Double {
        Double(nanos) / 1_000_000
    }
}

/// An ``InputLatencyHistogram`` as report fields: `count`, `buckets` (one per edge of
/// ``InputLatencyBuckets/edgesNanos``, then over), `p50_ms`, `p95_ms`, `p99_ms`, `max_ms` (absent
/// when empty).
public struct InputLatencyHistogramSnapshot: Sendable, Equatable, Codable {
    public var count: UInt64
    public var buckets: [UInt64]
    public var p50Milliseconds: Double?
    public var p95Milliseconds: Double?
    public var p99Milliseconds: Double?
    public var maxMilliseconds: Double?

    public init(count: UInt64, buckets: [UInt64], p50Milliseconds: Double?, p95Milliseconds: Double?,
                p99Milliseconds: Double?, maxMilliseconds: Double?) {
        self.count = count
        self.buckets = buckets
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.p99Milliseconds = p99Milliseconds
        self.maxMilliseconds = maxMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case count
        case buckets
        case p50Milliseconds = "p50_ms"
        case p95Milliseconds = "p95_ms"
        case p99Milliseconds = "p99_ms"
        case maxMilliseconds = "max_ms"
    }
}

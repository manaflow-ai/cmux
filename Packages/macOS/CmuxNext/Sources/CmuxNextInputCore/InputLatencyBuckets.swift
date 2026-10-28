/// The bucket edges input latency histograms count into: 1, 2, 4, 6, 8.3, 10, 12, 16.7, 24, 33,
/// 50, 100 and 250 ms, then one overflow bucket. 8.3 and 16.7 ms are one frame at 120 and 60 Hz,
/// the key-to-frame targets (p04-input.md, goals).
///
/// Bucket `i` counts values in (edge[i-1], edge[i]]; bucket 0 counts values up to the first edge
/// and the last bucket counts values above the last edge.
public struct InputLatencyBuckets: Sendable, Equatable {
    /// The upper edge of each bucket but the overflow one, in nanoseconds.
    public static let edgesNanos: [UInt64] = [
        1_000_000, 2_000_000, 4_000_000, 6_000_000, 8_300_000, 10_000_000, 12_000_000,
        16_700_000, 24_000_000, 33_000_000, 50_000_000, 100_000_000, 250_000_000,
    ]
    /// Buckets including the overflow one.
    public static let bucketCount = edgesNanos.count + 1

    /// The count per bucket (``bucketCount`` entries).
    public private(set) var counts: [UInt64]

    /// Empty buckets.
    public init() {
        counts = [UInt64](repeating: 0, count: Self.bucketCount)
    }

    /// The bucket `nanos` falls in.
    public static func bucket(forNanos nanos: UInt64) -> Int {
        var low = 0
        var high = edgesNanos.count
        while low < high {
            let middle = (low + high) / 2
            if nanos <= edgesNanos[middle] { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// Counts one value.
    public mutating func record(nanos: UInt64) {
        counts[Self.bucket(forNanos: nanos)] &+= 1
    }

    /// Counts `values` values of `nanos` at once.
    public mutating func record(nanos: UInt64, count values: UInt64) {
        counts[Self.bucket(forNanos: nanos)] &+= values
    }

    /// Adds `other`'s count to each bucket.
    public mutating func add(_ other: InputLatencyBuckets) {
        for index in counts.indices { counts[index] &+= other.counts[index] }
    }

    /// Values counted.
    public var total: UInt64 {
        counts.reduce(0, &+)
    }
}

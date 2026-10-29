#if DEBUG || CMUX_BENCH_HOOKS
/// A distribution of run times in microseconds (`debug.invariants {rules: true}`, `us`): 10 µs buckets up to 1 ms
/// and one bucket above it, so a percentile is exact to 10 µs where the rule budget (250 µs) is judged. It also
/// counts the runs above its own limit, so judging "p95 over the limit" after each run is one comparison, not a
/// scan of the buckets.
struct InvariantTiming: Hashable, Sendable {
    static let bucketMicros = 10.0
    static let bucketCount = 101

    private var buckets: [UInt32] = Array(repeating: 0, count: 101)
    private(set) var count: UInt64 = 0
    private(set) var maxMicros: Double = 0
    /// The run time this timing is judged against (``isOverLimit(at:)``).
    let limitMicros: Double
    /// Runs that took longer than ``limitMicros``.
    private(set) var overLimit: UInt64 = 0

    init(limitMicros: Double) {
        self.limitMicros = limitMicros
    }

    mutating func record(_ duration: Duration) {
        let micros = max(0, Self.micros(duration))
        let bucket = Int(min(Double(Self.bucketCount - 1), (micros / Self.bucketMicros).rounded(.down)))
        buckets[bucket] &+= 1
        count += 1
        maxMicros = max(maxMicros, micros)
        if micros > limitMicros { overLimit += 1 }
    }

    /// Whether the `fraction` percentile is above ``limitMicros``: more than `1 - fraction` of the runs were. O(1).
    func isOverLimit(at fraction: Double) -> Bool {
        Double(overLimit) > Double(count) * (1 - fraction)
    }

    /// The upper edge of the bucket that holds the `fraction` percentile (the maximum above the last edge), 0 with
    /// no run.
    func percentile(_ fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let target = UInt64((Double(count) * fraction).rounded(.up))
        var seen: UInt64 = 0
        for (index, hits) in buckets.enumerated() {
            seen += UInt64(hits)
            if seen >= target {
                return index == Self.bucketCount - 1 ? maxMicros : min(maxMicros, Double(index + 1) * Self.bucketMicros)
            }
        }
        return maxMicros
    }

    static func micros(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000_000 + Double(parts.attoseconds) / 1_000_000_000_000
    }
}
#endif

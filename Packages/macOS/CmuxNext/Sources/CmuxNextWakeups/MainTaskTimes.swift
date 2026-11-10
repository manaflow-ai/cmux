/// The always-on record of each scheduled main-thread task's time, per owner (plans/cmux-next/main-thread-scheduling.md
/// 1.2, gap G3): ``MainFrameBudget/run(_:owner:_:)`` adds every task's own time, of any class, to its owner's
/// histogram, and `debug.main_budget` reports per owner its count, p50 / p95 / p99, max and total.
///
/// The cost on the task's path is what the action budget ring (`ActionSampleRing`) costs an action: no allocation, no lock, no string, no
/// formatting. The storage is one raw buffer allocated at init, indexed by the owner's board index (interned when its
/// queue or method was built, ``MainTaskOwner``); a record is a bucket index from the duration's leading bit and a few
/// stores. Owners past ``capacity`` (board indices are not reused) share slot 0, which no task has (the board's "no
/// task"). This is a measurement with no off path: there is no setting and no switch.
///
/// Buckets are logarithmic, 4 per octave of microseconds (a quantile is at most a quarter above the true value),
/// from 1 µs to 57 ms; longer tasks share the last bucket, and the max is exact.
///
/// Not `Sendable`: only its budget (main actor) holds it. `nonisolated`, so its `deinit` frees the buffer wherever the
/// budget is released.
nonisolated final class MainTaskTimes {
    /// Owner slots (board indices `1..<capacity`; slot 0 holds every owner past it).
    let capacity: Int
    static let bucketCount = 64
    /// A task over this is the failure line of the main-thread rule (main-thread-scheduling.md 1.1).
    static let failureNanos: UInt64 = 8_000_000

    /// `capacity * bucketCount` counts, then per slot: count, over-8-ms count, total ns, max ns.
    private let buckets: UnsafeMutablePointer<UInt32>
    private let counts: UnsafeMutablePointer<UInt32>
    private let failures: UnsafeMutablePointer<UInt32>
    private let totals: UnsafeMutablePointer<UInt64>
    private let maxima: UnsafeMutablePointer<UInt64>

    init(capacity: Int) {
        self.capacity = max(capacity, 2)
        buckets = .allocate(capacity: self.capacity * Self.bucketCount)
        counts = .allocate(capacity: self.capacity)
        failures = .allocate(capacity: self.capacity)
        totals = .allocate(capacity: self.capacity)
        maxima = .allocate(capacity: self.capacity)
        reset()
    }

    deinit {
        buckets.deallocate()
        counts.deallocate()
        failures.deallocate()
        totals.deallocate()
        maxima.deallocate()
    }

    /// Adds one task of the owner at board index `owner` that took `nanos` of its own time.
    func record(owner: UInt32, nanos: UInt64) {
        let slot = Int(owner) < capacity ? Int(owner) : 0
        buckets[slot &* Self.bucketCount &+ Self.bucket(nanos)] &+= 1
        counts[slot] &+= 1
        if nanos > Self.failureNanos { failures[slot] &+= 1 }
        totals[slot] &+= nanos
        if nanos > maxima[slot] { maxima[slot] = nanos }
    }

    /// Clears every slot.
    func reset() {
        buckets.initialize(repeating: 0, count: capacity * Self.bucketCount)
        counts.initialize(repeating: 0, count: capacity)
        failures.initialize(repeating: 0, count: capacity)
        totals.initialize(repeating: 0, count: capacity)
        maxima.initialize(repeating: 0, count: capacity)
    }

    /// One slot with tasks: its index, count, tasks over 8 ms, total, max and the p50 / p95 / p99 bucket edges
    /// (each clamped to the max).
    struct Slot {
        var index: Int
        var count: Int
        var failures: Int
        var totalNanos: UInt64
        var maxNanos: UInt64
        var p50Nanos: UInt64
        var p95Nanos: UInt64
        var p99Nanos: UInt64
    }

    /// The slots with at least one task (for the report; never on a task's path).
    func slots() -> [Slot] {
        (0..<capacity).compactMap { slot in
            let count = Int(counts[slot])
            guard count > 0 else { return nil }
            let maximum = maxima[slot]
            return Slot(index: slot, count: count, failures: Int(failures[slot]), totalNanos: totals[slot], maxNanos: maximum,
                        p50Nanos: min(quantile(slot, 0.50, count: count), maximum),
                        p95Nanos: min(quantile(slot, 0.95, count: count), maximum),
                        p99Nanos: min(quantile(slot, 0.99, count: count), maximum))
        }
    }

    /// The upper edge of the bucket that holds the `q` quantile task of `slot`.
    private func quantile(_ slot: Int, _ q: Double, count: Int) -> UInt64 {
        let rank = max(1, Int((q * Double(count)).rounded(.up)))
        var seen = 0
        for bucket in 0..<Self.bucketCount {
            seen += Int(buckets[slot * Self.bucketCount + bucket])
            if seen >= rank { return Self.upperEdgeNanos(bucket) }
        }
        return .max
    }

    /// The bucket of `nanos`: 0 under 1 µs, then 4 per octave of microseconds, the last one open-ended.
    static func bucket(_ nanos: UInt64) -> Int {
        let micros = nanos / 1_000
        guard micros > 0 else { return 0 }
        let octave = 63 - micros.leadingZeroBitCount
        let quarter = octave >= 2 ? Int(truncatingIfNeeded: (micros >> UInt64(octave - 2)) & 3) : (octave == 1 ? Int(micros & 1) * 2 : 0)
        return min(1 + octave * 4 + quarter, bucketCount - 1)
    }

    /// The first duration past `bucket`; the last bucket has none.
    static func upperEdgeNanos(_ bucket: Int) -> UInt64 {
        guard bucket > 0 else { return 1_000 }
        guard bucket < bucketCount - 1 else { return .max }
        // Bucket b >= 1: octave (b - 1) / 4, quarter (b - 1) % 4. From octave 2 on a quarter is a quarter of the octave;
        // below it a bucket holds one whole microsecond (1, 2 or 3).
        let octave = (bucket - 1) / 4
        let quarter = UInt64((bucket - 1) % 4)
        guard octave >= 2 else { return ((1 << UInt64(octave)) + (octave == 1 ? quarter / 2 : 0) + 1) * 1_000 }
        return (1 << UInt64(octave)) / 4 * (5 + quarter) * 1_000
    }
}

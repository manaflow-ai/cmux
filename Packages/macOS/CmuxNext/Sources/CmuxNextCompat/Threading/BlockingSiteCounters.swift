#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics

/// The per-site atomics of one ``BlockingContext``: a call count, a wall-time total and a maximum
/// (nanoseconds) per site id. Fixed at init, so a recording thread never allocates; any thread adds,
/// any thread reads.
final class BlockingSiteCounters: Sendable {
    private let capacity: Int
    nonisolated(unsafe) private let counts: UnsafeMutablePointer<UnsafeAtomic<Int>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation
    nonisolated(unsafe) private let totalNanos: UnsafeMutablePointer<UnsafeAtomic<UInt64>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation
    nonisolated(unsafe) private let maxNanos: UnsafeMutablePointer<UnsafeAtomic<UInt64>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation

    init(capacity: Int) {
        self.capacity = capacity
        counts = .allocate(capacity: capacity)
        totalNanos = .allocate(capacity: capacity)
        maxNanos = .allocate(capacity: capacity)
        for slot in 0..<capacity {
            (counts + slot).initialize(to: UnsafeAtomic<Int>.Storage(0))
            (totalNanos + slot).initialize(to: UnsafeAtomic<UInt64>.Storage(0))
            (maxNanos + slot).initialize(to: UnsafeAtomic<UInt64>.Storage(0))
        }
    }

    deinit {
        counts.deinitialize(count: capacity)
        counts.deallocate()
        totalNanos.deinitialize(count: capacity)
        totalNanos.deallocate()
        maxNanos.deinitialize(count: capacity)
        maxNanos.deallocate()
    }

    /// Counts one ended call at `site` and adds its `nanos` (nil: not timed) to the site's total and maximum.
    func add(site: Int, nanos: UInt64?) {
        if let nanos {
            UnsafeAtomic<UInt64>(at: totalNanos + site).wrappingIncrement(by: nanos, ordering: .relaxed)
            let maximum = UnsafeAtomic<UInt64>(at: maxNanos + site)
            var seen = maximum.load(ordering: .relaxed)
            while nanos > seen {
                let (exchanged, original) = maximum.weakCompareExchange(expected: seen, desired: nanos, ordering: .relaxed)
                if exchanged { break }
                seen = original
            }
        }
        UnsafeAtomic<Int>(at: counts + site).wrappingIncrement(ordering: .relaxed)
    }

    /// The site's count and wall times now.
    func read(site: Int) -> (count: Int, totalNanos: UInt64, maxNanos: UInt64) {
        (UnsafeAtomic<Int>(at: counts + site).load(ordering: .relaxed),
         UnsafeAtomic<UInt64>(at: totalNanos + site).load(ordering: .relaxed),
         UnsafeAtomic<UInt64>(at: maxNanos + site).load(ordering: .relaxed))
    }

    /// Zeroes every site.
    func reset() {
        for slot in 0..<capacity {
            UnsafeAtomic<Int>(at: counts + slot).store(0, ordering: .relaxed)
            UnsafeAtomic<UInt64>(at: totalNanos + slot).store(0, ordering: .relaxed)
            UnsafeAtomic<UInt64>(at: maxNanos + slot).store(0, ordering: .relaxed)
        }
    }
}
#endif

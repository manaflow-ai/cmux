#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics

/// The per-site atomics of one ``BlockingContext``: a call count, a wall-time total and a maximum
/// (nanoseconds) per site id, in one fixed allocation of three words per site. Fixed at init, so a recording
/// thread never allocates; any thread adds, any thread reads.
final class BlockingSiteCounters: Sendable {
    private let capacity: Int
    /// Site `id` owns words `3 * id` (count), `3 * id + 1` (total) and `3 * id + 2` (maximum).
    nonisolated(unsafe) private let words: UnsafeMutablePointer<UnsafeAtomic<UInt64>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation

    init(capacity: Int) {
        self.capacity = capacity
        words = .allocate(capacity: capacity * 3)
        for slot in 0..<(capacity * 3) {
            (words + slot).initialize(to: UnsafeAtomic<UInt64>.Storage(0))
        }
    }

    deinit {
        words.deinitialize(count: capacity * 3)
        words.deallocate()
    }

    private func word(_ site: Int, _ field: Int) -> UnsafeAtomic<UInt64> {
        UnsafeAtomic<UInt64>(at: words + (site * 3 + field))
    }

    /// Counts one ended call at `site` and adds its `nanos` (nil: not timed) to the site's total and maximum.
    func add(site: Int, nanos: UInt64?) {
        if let nanos {
            word(site, 1).wrappingIncrement(by: nanos, ordering: .relaxed)
            let maximum = word(site, 2)
            var seen = maximum.load(ordering: .relaxed)
            while nanos > seen {
                let (exchanged, original) = maximum.weakCompareExchange(expected: seen, desired: nanos, ordering: .relaxed)
                if exchanged { break }
                seen = original
            }
        }
        word(site, 0).wrappingIncrement(ordering: .relaxed)
    }

    /// The site's count and wall times now.
    func read(site: Int) -> (count: Int, totalNanos: UInt64, maxNanos: UInt64) {
        (Int(truncatingIfNeeded: word(site, 0).load(ordering: .relaxed)),
         word(site, 1).load(ordering: .relaxed),
         word(site, 2).load(ordering: .relaxed))
    }

    /// Zeroes every site.
    func reset() {
        for slot in 0..<(capacity * 3) {
            UnsafeAtomic<UInt64>(at: words + slot).store(0, ordering: .relaxed)
        }
    }
}
#endif

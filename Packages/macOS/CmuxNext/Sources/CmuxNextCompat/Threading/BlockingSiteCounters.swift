#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics
import class CmuxSafeConcurrency.Invariant

/// The per-site atomics of one ``BlockingContext``: a call count, a wall-time total and a maximum
/// (nanoseconds) per site id, in one fixed allocation of three words per site. Fixed at init, so a recording
/// thread never allocates; any thread adds, any thread reads.
///
/// Memory safety: `words` is the one allocation of `capacity * 3` initialized words that init made; deinit
/// deinitializes and frees it once. Every word is reached through ``word(_:)``; the methods take only a site id
/// under `capacity` (another is ignored or reads as zero), so its index is inside the table.
@safe
final class BlockingSiteCounters: Sendable {
    private let capacity: Int
    /// Site `id` owns words `3 * id` (count), `3 * id + 1` (total) and `3 * id + 2` (maximum).
    nonisolated(unsafe) private let words: UnsafeMutablePointer<UnsafeAtomic<UInt64>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation

    init(capacity: Int) {
        self.capacity = capacity
        // SAFETY: a fresh allocation of capacity * 3 words, each initialized to zero here; freed once, in deinit.
        unsafe words = UnsafeMutablePointer<UnsafeAtomic<UInt64>.Storage>.allocate(capacity: capacity * 3)
        for slot in 0..<(capacity * 3) {
            unsafe (words + slot).initialize(to: UnsafeAtomic<UInt64>.Storage(0))
        }
    }

    deinit {
        // SAFETY: the allocation of init, capacity * 3 initialized words; nothing else holds `self` any more.
        unsafe words.deinitialize(count: capacity * 3)
        unsafe words.deallocate()
    }

    /// Word `index` of the table. Every caller passes an index under capacity * 3.
    private func word(_ index: Int) -> UnsafeAtomic<UInt64> {
        Invariant.debugCheck(index >= 0 && index < capacity * 3, "blocking-site-counter-in-range")
        // SAFETY: 0 <= index < capacity * 3 (every caller's bound), so the word is inside the allocation, which
        // lives as long as `self`.
        return unsafe UnsafeAtomic<UInt64>(at: words + index)
    }

    private func holds(_ site: Int) -> Bool { site >= 0 && site < capacity }

    private func word(_ site: Int, _ field: Int) -> UnsafeAtomic<UInt64> {
        word(site * 3 + field)
    }

    /// Counts one ended call at `site` and adds its `nanos` (nil: not timed) to the site's total and maximum.
    func add(site: Int, nanos: UInt64?) {
        guard holds(site) else { return }
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
        guard holds(site) else { return (0, 0, 0) }
        return (Int(truncatingIfNeeded: word(site, 0).load(ordering: .relaxed)),
                word(site, 1).load(ordering: .relaxed),
                word(site, 2).load(ordering: .relaxed))
    }

    /// Zeroes every site.
    func reset() {
        for slot in 0..<(capacity * 3) {
            word(slot).store(0, ordering: .relaxed)
        }
    }
}
#endif

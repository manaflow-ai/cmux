#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics
import class CmuxSafeConcurrency.Invariant

/// The pool's call sites by ``BlockingSiteKey``: the shape of ``BlockingSiteIndex`` (a fixed open-addressing
/// table, twice the site limit, never allocates after its init), but any thread may ``find(_:)`` while one
/// thread at a time inserts. A repeat of a known pool site therefore takes no lock.
///
/// Each slot is three atomic words: the key's two halves and the site id plus one (0: empty). A slot is
/// written once and never cleared: the inserter stores the key halves, then publishes the id with a release
/// store; a reader loads the id with acquire, so it never reads a half-written key. A reader that runs into a
/// slot an insert is still filling reads it as empty and misses the site; the caller then takes the insert
/// path, which probes again with inserts serialized and finds it.
///
/// Memory safety: `words` is the one allocation of `slotCount * 3` initialized words that init made; deinit
/// deinitializes and frees it once. Every word is reached through ``word(_:_:)``, whose slot is a probe position
/// modulo `slotCount` and whose field is 0, 1 or 2.
@safe
final class BlockingSharedSiteIndex: Sendable {
    private let slotCount: Int
    private let limit: Int
    /// Slot `s` owns words `3 * s` (key first), `3 * s + 1` (key second) and `3 * s + 2` (id + 1).
    nonisolated(unsafe) private let words: UnsafeMutablePointer<UnsafeAtomic<UInt>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation
    private let insertedCount = UnsafeAtomic<Int>.create(0)

    /// An index of at most `capacity` sites.
    init(capacity: Int) {
        limit = capacity
        slotCount = capacity * 2
        // SAFETY: a fresh allocation of slotCount * 3 words, each initialized to zero here; freed once, in deinit.
        unsafe words = UnsafeMutablePointer<UnsafeAtomic<UInt>.Storage>.allocate(capacity: slotCount * 3)
        for word in 0..<(slotCount * 3) {
            unsafe (words + word).initialize(to: UnsafeAtomic<UInt>.Storage(0))
        }
    }

    deinit {
        // SAFETY: the allocation of init, slotCount * 3 initialized words; nothing else holds `self` any more.
        unsafe words.deinitialize(count: slotCount * 3)
        unsafe words.deallocate()
        insertedCount.destroy()
    }

    private func word(_ slot: Int, _ field: Int) -> UnsafeAtomic<UInt> {
        Invariant.debugCheck(slot >= 0 && slot < slotCount && field >= 0 && field < 3, "blocking-site-index-word-in-range")
        // SAFETY: slot * 3 + field is under slotCount * 3 (the bounds above), so the word is inside the allocation,
        // which lives as long as `self`.
        return unsafe UnsafeAtomic<UInt>(at: words + (slot * 3 + field))
    }

    /// The site id of `key`, if its insert was published. Any thread, no lock. At most every slot is probed
    /// (the table is never more than half full, so a probe ends at an empty slot first).
    func find(_ key: BlockingSiteKey) -> Int? {
        var slot = Self.start(key, slotCount)
        for _ in 0..<slotCount {
            let id = word(slot, 2).load(ordering: .acquiring)
            if id == 0 { return nil }
            if word(slot, 0).load(ordering: .relaxed) == key.first && word(slot, 1).load(ordering: .relaxed) == key.second {
                return Int(id) - 1
            }
            slot = (slot + 1) % slotCount
        }
        return nil
    }

    /// Whether every id is taken (any thread; a new site past it only counts as overflow).
    var isFull: Bool { insertedCount.load(ordering: .relaxed) >= limit }

    /// The id the next new site gets, or nil when the index is full. Inserting thread only.
    var nextID: Int? {
        let count = insertedCount.load(ordering: .relaxed)
        return count < limit ? count : nil
    }

    /// Adds `key` (not found by the inserting thread; ``nextID`` was not nil) under the id ``nextID`` named.
    /// One inserting thread at a time.
    func insert(_ key: BlockingSiteKey) {
        let id = insertedCount.load(ordering: .relaxed)
        guard id < limit, key != .empty else { return }
        var slot = Self.start(key, slotCount)
        while word(slot, 2).load(ordering: .relaxed) != 0 { slot = (slot + 1) % slotCount }
        word(slot, 0).store(key.first, ordering: .relaxed)
        word(slot, 1).store(key.second, ordering: .relaxed)
        word(slot, 2).store(UInt(id + 1), ordering: .releasing)
        insertedCount.store(id + 1, ordering: .relaxed)
    }

    private static func start(_ key: BlockingSiteKey, _ size: Int) -> Int {
        Int(UInt(bitPattern: key.hash) % UInt(size))
    }
}
#endif

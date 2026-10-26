#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics

/// A fixed single-producer, single-consumer ring of ``BlockingPendingCall``s: the main thread
/// pushes, the drain queue pops. Lock-free and allocation-free after its init, so the violation
/// path never waits for the drain and never runs the drain's work.
///
/// Memory safety: `slots` is the one allocation of `capacity` initialized slots that init made; deinit
/// deinitializes and frees it once. Every index is a counter modulo `capacity`, so it is inside it.
@safe
final class BlockingPendingRing: @unchecked Sendable { // crash-allow: one producer (the main thread) writes a slot before it publishes `tail` (release); one consumer (the drain queue) reads it after it loads `tail` (acquire) and frees it by publishing `head`
    private let slots: UnsafeMutablePointer<BlockingPendingCall?>
    private let capacity: Int
    private let head = UnsafeAtomic<Int>.create(0)
    private let tail = UnsafeAtomic<Int>.create(0)

    init(capacity: Int) {
        self.capacity = capacity
        // SAFETY: a fresh allocation of `capacity` slots, every one initialized to nil here; freed once, in deinit.
        unsafe slots = UnsafeMutablePointer<BlockingPendingCall?>.allocate(capacity: capacity)
        unsafe slots.initialize(repeating: nil, count: capacity)
    }

    deinit {
        // SAFETY: the allocation of init, `capacity` initialized slots; nothing else holds `self` any more.
        unsafe slots.deinitialize(count: capacity)
        unsafe slots.deallocate()
        head.destroy()
        tail.destroy()
    }

    /// Adds `call` (producer only); false when the ring is full.
    func push(_ call: BlockingPendingCall) -> Bool {
        let end = tail.load(ordering: .relaxed)
        guard end - head.load(ordering: .acquiring) < capacity else { return false }
        // SAFETY: end % capacity is under capacity (end >= 0); the consumer freed this slot before it published `head`.
        unsafe slots[end % capacity] = call
        tail.store(end + 1, ordering: .releasing)
        return true
    }

    /// Takes the oldest call (consumer only); nil when the ring is empty.
    func pop() -> BlockingPendingCall? {
        let start = head.load(ordering: .relaxed)
        guard start < tail.load(ordering: .acquiring) else { return nil }
        // SAFETY: start % capacity is under capacity (start >= 0); the producer wrote this slot before it published
        // `tail`.
        let call = unsafe slots[start % capacity]
        unsafe slots[start % capacity] = nil
        head.store(start + 1, ordering: .releasing)
        return call
    }
}
#endif

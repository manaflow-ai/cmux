#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics

/// A fixed single-producer, single-consumer ring of ``BlockingPendingCall``s: the main thread
/// pushes, the drain queue pops. Lock-free and allocation-free after its init, so the violation
/// path never waits for the drain and never runs the drain's work.
final class BlockingPendingRing: @unchecked Sendable { // crash-allow: one producer (the main thread) writes a slot before it publishes `tail` (release); one consumer (the drain queue) reads it after it loads `tail` (acquire) and frees it by publishing `head`
    private let slots: UnsafeMutablePointer<BlockingPendingCall?>
    private let capacity: Int
    private let head = UnsafeAtomic<Int>.create(0)
    private let tail = UnsafeAtomic<Int>.create(0)

    init(capacity: Int) {
        self.capacity = capacity
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: nil, count: capacity)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
        head.destroy()
        tail.destroy()
    }

    /// Adds `call` (producer only); false when the ring is full.
    func push(_ call: BlockingPendingCall) -> Bool {
        let end = tail.load(ordering: .relaxed)
        guard end - head.load(ordering: .acquiring) < capacity else { return false }
        slots[end % capacity] = call
        tail.store(end + 1, ordering: .releasing)
        return true
    }

    /// Takes the oldest call (consumer only); nil when the ring is empty.
    func pop() -> BlockingPendingCall? {
        let start = head.load(ordering: .relaxed)
        guard start < tail.load(ordering: .acquiring) else { return nil }
        let call = slots[start % capacity]
        slots[start % capacity] = nil
        head.store(start + 1, ordering: .releasing)
        return call
    }
}
#endif

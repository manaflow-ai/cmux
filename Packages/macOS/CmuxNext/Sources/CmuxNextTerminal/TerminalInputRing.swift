import CmuxNextCompat

/// The lane's single-producer, single-consumer ring and the drain queue's backlog. Slots are
/// preallocated boxes in an array that never changes after init, so no write races the array itself.
nonisolated final class TerminalInputRing: @unchecked Sendable { // crash-allow: one producer (the main thread) fills slot `tail` before it publishes `tail` (releasing) and one consumer (the drain queue) reads it after loading `tail` (acquiring) and frees it by publishing `head`; `backlog` and `backlogStart` are the drain queue's alone
    let capacity: Int
    private let slots: [TerminalInputSlot]
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    /// True while the drain handler holds a record (``TerminalInputDrain/Next/hold``).
    let held = Atomic<Bool>(false)
    private var backlog: [TerminalInputRecord] = []
    private var backlogStart = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        slots = (0..<max(1, capacity)).map { _ in TerminalInputSlot() }
    }

    /// Producer (the main thread) only. False when the ring is full.
    func push(_ record: TerminalInputRecord) -> Bool {
        let end = tail.load(ordering: .relaxed)
        guard end - head.load(ordering: .acquiring) < capacity else { return false }
        slots[end % capacity].record = record
        tail.store(end + 1, ordering: .releasing)
        return true
    }

    /// Consumer only: the oldest ring record, nil when the ring is empty.
    func pop() -> TerminalInputRecord? {
        let start = head.load(ordering: .relaxed)
        guard start < tail.load(ordering: .acquiring) else { return nil }
        let slot = slots[start % capacity]
        let record = slot.record
        slot.record = nil
        head.store(start + 1, ordering: .releasing)
        return record
    }

    /// Consumer only: moves every ring record, then `later`, to the end of the backlog.
    func moveToBacklog(then later: [TerminalInputRecord]) {
        while let record = pop() { backlog.append(record) }
        backlog.append(contentsOf: later)
    }

    /// Consumer only: the backlog's oldest record, nil when it is empty.
    func takeBacklog() -> TerminalInputRecord? {
        guard backlogStart < backlog.count else { return nil }
        let record = backlog[backlogStart]
        backlogStart += 1
        if backlogStart == backlog.count {
            backlog.removeAll(keepingCapacity: true)
            backlogStart = 0
        }
        return record
    }
}

/// One ring slot: written by the producer before it publishes the slot, read by the consumer after.
private nonisolated final class TerminalInputSlot {
    var record: TerminalInputRecord?
}

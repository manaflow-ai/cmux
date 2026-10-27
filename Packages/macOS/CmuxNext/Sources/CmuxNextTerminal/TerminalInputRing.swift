import CmuxNextCompat

/// The lane's single-producer, single-consumer ring and the drain queue's backlog.
///
/// The producer (the main thread) fills slot `tail` and then publishes `tail` (releasing); the consumer
/// (the drain queue) reads a slot only after loading `tail` (acquiring) and frees it by publishing `head`.
/// So the two never touch one slot at once: each slot's `Mutex` is never contended, and the producer
/// takes it with `withLockIfAvailable`, which cannot wait. The slots are preallocated at init and the
/// array never changes after it.
nonisolated final class TerminalInputRing: Sendable {
    let capacity: Int
    private let slots: [TerminalInputSlot]
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    /// True while the drain handler holds a record (``TerminalInputDrain/Next/hold``).
    let held = Atomic<Bool>(false)
    // Lock carve-out: the drain queue's alone (the consumer), so never contended.
    private let backlog = Mutex(TerminalInputBacklog())

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        slots = (0..<max(1, capacity)).map { _ in TerminalInputSlot() }
    }

    /// Producer (the main thread) only. False when the ring is full. Never waits.
    func push(_ record: TerminalInputRecord) -> Bool {
        let end = tail.load(ordering: .relaxed)
        guard end - head.load(ordering: .acquiring) < capacity else { return false }
        guard slots[end % capacity].record.withLockIfAvailable({ $0 = record }) != nil else { return false }
        tail.store(end + 1, ordering: .releasing)
        return true
    }

    /// Consumer only: the oldest ring record, nil when the ring is empty.
    func pop() -> TerminalInputRecord? {
        let start = head.load(ordering: .relaxed)
        guard start < tail.load(ordering: .acquiring) else { return nil }
        let record = slots[start % capacity].record.withLock { slot -> TerminalInputRecord? in
            defer { slot = nil }
            return slot
        }
        head.store(start + 1, ordering: .releasing)
        return record
    }

    /// Consumer only: moves every ring record to the end of the backlog.
    func moveToBacklog() {
        backlog.withLock { backlog in
            while let record = pop() { backlog.append(record) }
        }
    }

    /// Consumer only: puts `later` after every record in the backlog.
    func appendToBacklog(_ later: [TerminalInputRecord]) {
        guard !later.isEmpty else { return }
        backlog.withLock { $0.append(contentsOf: later) }
    }

    /// Consumer only: the backlog's oldest record, nil when it is empty.
    func takeBacklog() -> TerminalInputRecord? {
        backlog.withLock { $0.take() }
    }
}

/// One ring slot (``TerminalInputRing``).
private nonisolated final class TerminalInputSlot: Sendable {
    let record = Mutex<TerminalInputRecord?>(nil)
}

/// Records the consumer moved out of the ring and the overflow together, oldest first.
private nonisolated struct TerminalInputBacklog {
    private var records: [TerminalInputRecord] = []
    private var start = 0

    mutating func append(_ record: TerminalInputRecord) {
        records.append(record)
    }

    /// Takes `more`'s storage when the backlog is empty (no copy), else appends it.
    mutating func append(contentsOf more: [TerminalInputRecord]) {
        if start == records.count {
            records = more
            start = 0
        } else {
            records.append(contentsOf: more)
        }
    }

    mutating func take() -> TerminalInputRecord? {
        guard start < records.count else { return nil }
        let record = records[start]
        start += 1
        if start == records.count {
            records.removeAll(keepingCapacity: true)
            start = 0
        }
        return record
    }
}

/// The reply deadlines of one connection's requests, earliest first, so the connection arms one timer for
/// the earliest of them instead of one timer per request. Chrome keeps a sequence's delayed tasks the same
/// way: one heap (`DelayedIncomingQueue`, base/task/sequence_manager/task_queue_impl.h) whose top sets the
/// one wake-up the sequence asks for (base/task/sequence_manager/wake_up_queue.cc).
///
/// A request answered before its deadline leaves at once (``remove(id:)``, O(log n) through the position
/// index), so the heap holds only requests that still wait and a fire never fails an answered one. Equal
/// deadlines come out in id order, which is send order: a pipelined group expires in its order.
nonisolated struct DeadlineHeap {
    /// When a request stops waiting for its reply: ``at`` on the connection's clock (time since it opened),
    /// and the request's timeout, for its error.
    struct Deadline: Equatable {
        var at: Duration
        var timeout: Duration
    }

    struct Entry: Equatable {
        var id: UInt64
        var deadline: Deadline
    }

    private var entries: [Entry] = []
    /// Each entry's slot in `entries`.
    private var positions: [UInt64: Int] = [:]

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    /// The earliest deadline.
    var first: Entry? { entries.first }

    /// Adds `id`'s deadline; an id already in the heap gets the new one.
    mutating func insert(id: UInt64, _ deadline: Deadline) {
        if let slot = positions[id] {
            entries.modify(checked: slot) { $0.deadline = deadline }
            restore(slot)
            return
        }
        entries.append(Entry(id: id, deadline: deadline))
        positions[id] = entries.count - 1
        siftUp(entries.count - 1)
    }

    /// Takes `id`'s deadline out; nil when it has none.
    @discardableResult
    mutating func remove(id: UInt64) -> Entry? {
        guard let slot = positions[id] else { return nil }
        return remove(at: slot)
    }

    /// Takes out the earliest deadline when it is at or before `now`.
    mutating func popDue(at now: Duration) -> Entry? {
        guard let top = entries.first, top.deadline.at <= now else { return nil }
        return remove(at: 0)
    }

    mutating func removeAll() {
        entries.removeAll()
        positions.removeAll()
    }

    private mutating func remove(at slot: Int) -> Entry? {
        guard let removed = entries[checked: slot] else { return nil }
        let last = entries.count - 1
        if slot != last { swap(slot, last) }
        entries.removeLast()
        positions[removed.id] = nil
        if slot < entries.count { restore(slot) }
        return removed
    }

    /// True when the entry in `lhs` comes out before the one in `rhs`; false when either slot is empty.
    private func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
        guard let left = entries[checked: lhs], let right = entries[checked: rhs] else { return false }
        return (left.deadline.at, left.id) < (right.deadline.at, right.id)
    }

    private mutating func restore(_ slot: Int) {
        if slot > 0, precedes(slot, (slot - 1) / 2) {
            siftUp(slot)
        } else {
            siftDown(slot)
        }
    }

    private mutating func siftUp(_ start: Int) {
        var slot = start
        while slot > 0, precedes(slot, (slot - 1) / 2) {
            let parent = (slot - 1) / 2
            swap(slot, parent)
            slot = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var slot = start
        while let child = earlierChild(of: slot), precedes(child, slot) {
            swap(slot, child)
            slot = child
        }
    }

    /// The child of `slot` that comes out first; nil for a leaf.
    private func earlierChild(of slot: Int) -> Int? {
        let left = 2 * slot + 1
        guard left < entries.count else { return nil }
        let right = left + 1
        return right < entries.count && precedes(right, left) ? right : left
    }

    /// Swaps two slots that hold entries and keeps their positions.
    private mutating func swap(_ i: Int, _ j: Int) {
        guard let first = entries[checked: i], let second = entries[checked: j] else { return }
        entries.modify(checked: i) { $0 = second }
        entries.modify(checked: j) { $0 = first }
        positions[second.id] = i
        positions[first.id] = j
    }
}

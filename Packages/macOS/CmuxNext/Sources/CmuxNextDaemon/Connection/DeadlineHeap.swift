/// The reply deadlines of one connection's requests, earliest first, so the connection arms one timer for
/// the earliest of them instead of one timer per request. Chrome keeps a sequence's delayed tasks the same
/// way: one heap (`DelayedIncomingQueue`, base/task/sequence_manager/task_queue_impl.h) whose top sets the
/// one wake-up the sequence asks for (base/task/sequence_manager/wake_up_queue.cc).
///
/// A request answered before its deadline leaves at once (``remove(id:)``, O(log n) through the position
/// index), so the heap holds only requests that still wait and a fire never wakes for an answered one.
/// Equal deadlines come out in id order, which is send order: a pipelined group expires in its order.
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
    /// Each entry's index in `entries`.
    private var positions: [UInt64: Int] = [:]

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    /// The earliest deadline.
    var first: Entry? { entries.first }

    /// Adds `id`'s deadline; an id already in the heap gets the new one.
    mutating func insert(id: UInt64, _ deadline: Deadline) {
        if let index = positions[id] {
            entries[index].deadline = deadline
            restore(from: index)
            return
        }
        entries.append(Entry(id: id, deadline: deadline))
        positions[id] = entries.count - 1
        siftUp(from: entries.count - 1)
    }

    /// Takes `id`'s deadline out; nil when it has none.
    @discardableResult
    mutating func remove(id: UInt64) -> Entry? {
        guard let index = positions[id] else { return nil }
        return remove(at: index)
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

    private mutating func remove(at index: Int) -> Entry {
        let removed = entries[index]
        positions[removed.id] = nil
        let last = entries.removeLast()
        if index < entries.count {
            entries[index] = last
            positions[last.id] = index
            restore(from: index)
        }
        return removed
    }

    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        (lhs.deadline.at, lhs.id) < (rhs.deadline.at, rhs.id)
    }

    private mutating func restore(from index: Int) {
        if index > 0, Self.precedes(entries[index], entries[(index - 1) / 2]) {
            siftUp(from: index)
        } else {
            siftDown(from: index)
        }
    }

    private mutating func siftUp(from start: Int) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard Self.precedes(entries[index], entries[parent]) else { return }
            swapAt(index, parent)
            index = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var index = start
        while true {
            let left = 2 * index + 1
            guard left < entries.count else { return }
            let right = left + 1
            let child = right < entries.count && Self.precedes(entries[right], entries[left]) ? right : left
            guard Self.precedes(entries[child], entries[index]) else { return }
            swapAt(index, child)
            index = child
        }
    }

    private mutating func swapAt(_ i: Int, _ j: Int) {
        entries.swapAt(i, j)
        positions[entries[i].id] = i
        positions[entries[j].id] = j
    }
}

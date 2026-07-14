import Foundation

/// Amortized O(1) FIFO order for pending project-root requesters.
struct WorktreeSidebarRequesterQueue: Sendable {
    private var storage: [UUID] = []
    private var head = 0

    mutating func enqueue(_ requesterID: UUID) {
        storage.append(requesterID)
    }

    mutating func dequeue() -> UUID? {
        guard head < storage.count else {
            storage.removeAll(keepingCapacity: true)
            head = 0
            return nil
        }
        let requesterID = storage[head]
        head += 1
        compactIfNeeded()
        return requesterID
    }

    private mutating func compactIfNeeded() {
        guard head == storage.count || (head >= 64 && head * 2 >= storage.count) else {
            return
        }
        storage.removeFirst(head)
        head = 0
    }
}

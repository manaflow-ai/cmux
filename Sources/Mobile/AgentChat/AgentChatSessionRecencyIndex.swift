import Foundation

/// Main-actor-owned bounded min-heap for recent-session selection.
struct AgentChatSessionRecencyIndex {
    private typealias Entry = (sessionID: String, lastActivityAt: Date)

    private var entries: [Entry] = []
    private var indexBySessionID: [String: Int] = [:]
    private(set) var needsRebuild = false

    /// Creates an index retaining at most `capacity` recent sessions.
    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    private let capacity: Int

    /// Inserts or updates one session's recency key.
    mutating func upsert(sessionID: String, lastActivityAt: Date) {
        if let index = indexBySessionID[sessionID] {
            let previousDate = entries[index].lastActivityAt
            entries[index] = Entry(sessionID: sessionID, lastActivityAt: lastActivityAt)
            if lastActivityAt < previousDate {
                // A previously evicted record may now belong in the top-K set;
                // defer to the authoritative registry before the next query.
                needsRebuild = true
            }
            if !siftDown(from: index) {
                siftUp(from: index)
            }
            return
        }
        guard capacity > 0 else { return }
        let entry = Entry(sessionID: sessionID, lastActivityAt: lastActivityAt)
        guard entries.count < capacity else {
            guard isOlder(entries[0], than: entry) else { return }
            indexBySessionID.removeValue(forKey: entries[0].sessionID)
            entries[0] = entry
            indexBySessionID[entry.sessionID] = 0
            _ = siftDown(from: 0)
            return
        }
        indexBySessionID[sessionID] = entries.count
        entries.append(entry)
        _ = siftUp(from: entries.count - 1)
    }

    /// Removes one session from the index.
    mutating func remove(sessionID: String) {
        guard let index = indexBySessionID.removeValue(forKey: sessionID) else { return }
        needsRebuild = true
        let last = entries.removeLast()
        guard index < entries.count else { return }
        entries[index] = last
        indexBySessionID[last.sessionID] = index
        if !siftDown(from: index) {
            siftUp(from: index)
        }
    }

    /// Removes all retained entries so the owner can rebuild from authoritative records.
    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        indexBySessionID.removeAll(keepingCapacity: true)
        needsRebuild = false
    }

    /// Returns the most recent retained session IDs.
    func mostRecentSessionIDs(limit: Int) -> [String] {
        entries
            .sorted { lhs, rhs in
                if lhs.lastActivityAt != rhs.lastActivityAt {
                    return lhs.lastActivityAt > rhs.lastActivityAt
                }
                return lhs.sessionID < rhs.sessionID
            }
            .prefix(max(0, limit))
            .map(\.sessionID)
    }

    /// Moves an entry toward the heap root when it is older than its parent.
    /// - Returns: Whether the entry moved.
    @discardableResult
    private mutating func siftUp(from index: Int) -> Bool {
        var child = index
        var moved = false
        while child > 0 {
            let parent = (child - 1) / 2
            guard isOlder(entries[child], than: entries[parent]) else { break }
            swapAt(child, parent)
            child = parent
            moved = true
        }
        return moved
    }

    @discardableResult
    private mutating func siftDown(from index: Int) -> Bool {
        var parent = index
        var moved = false
        while true {
            let left = parent * 2 + 1
            guard left < entries.count else { return moved }
            var candidate = left
            let right = left + 1
            if right < entries.count, isOlder(entries[right], than: entries[left]) {
                candidate = right
            }
            guard isOlder(entries[candidate], than: entries[parent]) else { return moved }
            swapAt(parent, candidate)
            parent = candidate
            moved = true
        }
    }

    private func isOlder(_ lhs: Entry, than rhs: Entry) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt < rhs.lastActivityAt
        }
        return lhs.sessionID > rhs.sessionID
    }

    private mutating func swapAt(_ lhs: Int, _ rhs: Int) {
        entries.swapAt(lhs, rhs)
        indexBySessionID[entries[lhs].sessionID] = lhs
        indexBySessionID[entries[rhs].sessionID] = rhs
    }
}

/// A list's order (newest first) as a linked list over ids: inserting, removing or moving a row
/// anywhere costs O(1), and reading k ids from a point costs O(k). A flood of changes on a
/// 100,000-row list costs what the changes cost, not a pass over the list each.
struct PagedListOrder<ID: Hashable> {
    private(set) var head: ID?
    private(set) var tail: ID?
    private var next: [ID: ID] = [:]
    private var prev: [ID: ID] = [:]
    private var members: Set<ID> = []

    var count: Int { members.count }
    var isEmpty: Bool { members.isEmpty }

    func contains(_ id: ID) -> Bool { members.contains(id) }
    func after(_ id: ID) -> ID? { next[id] }
    func before(_ id: ID) -> ID? { prev[id] }

    /// Puts `id` at the newest end (moving it there if it is already in the list).
    mutating func insertAtHead(_ id: ID) {
        if members.contains(id) {
            guard head != id else { return }
            remove(id)
        }
        members.insert(id)
        if let old = head {
            next[id] = old
            prev[old] = id
        } else {
            tail = id
        }
        head = id
    }

    /// Puts `id` at the oldest end (moving it there if it is already in the list).
    mutating func append(_ id: ID) {
        if members.contains(id) {
            guard tail != id else { return }
            remove(id)
        }
        members.insert(id)
        if let old = tail {
            prev[id] = old
            next[old] = id
        } else {
            head = id
        }
        tail = id
    }

    /// Puts `id` right after `anchor` (older than it). Returns false when `anchor` is not in the list.
    @discardableResult
    mutating func insert(_ id: ID, after anchor: ID) -> Bool {
        guard id != anchor, members.contains(anchor) else { return false }
        if members.contains(id) {
            if next[anchor] == id { return true }
            remove(id)
        }
        members.insert(id)
        let following = next[anchor]
        next[anchor] = id
        prev[id] = anchor
        if let following {
            next[id] = following
            prev[following] = id
        } else {
            tail = id
        }
        return true
    }

    mutating func remove(_ id: ID) {
        guard members.remove(id) != nil else { return }
        let before = prev.removeValue(forKey: id)
        let after = next.removeValue(forKey: id)
        if let before { next[before] = after } else { head = after }
        if let after { prev[after] = before } else { tail = before }
    }

    /// Up to `count` ids from `start` toward the oldest end, `start` first.
    func ids(from start: ID?, count limit: Int) -> [ID] {
        var out: [ID] = []
        out.reserveCapacity(min(limit, members.count))
        var cursor = start
        while let id = cursor, out.count < limit {
            out.append(id)
            cursor = next[id]
        }
        return out
    }

    /// The id `steps` rows newer than `id` (or the head, when the list ends first).
    func walkBack(from id: ID, steps: Int) -> ID {
        var cursor = id
        var left = steps
        while left > 0, let before = prev[cursor] {
            cursor = before
            left -= 1
        }
        return cursor
    }

    /// Every id, newest first.
    func all() -> [ID] { ids(from: head, count: members.count) }
}

public import Foundation

/// What one commit did to an ordered list, as table edits: `removed` are positions before the
/// commit, `inserted` and `updated` positions after it. A row whose order key and membership did
/// not change is `updated` in place; any other changed row is removed and inserted.
public nonisolated struct FeedRowChanges: Sendable, Equatable {
    public var removed = IndexSet()
    public var inserted = IndexSet()
    public var updated = IndexSet()

    public init(removed: IndexSet = [], inserted: IndexSet = [], updated: IndexSet = []) {
        self.removed = removed
        self.inserted = inserted
        self.updated = updated
    }

    public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && updated.isEmpty }

    /// Where row `old` (before the commit) is after it; nil when it was removed. O(changes).
    public func newRow(forOld old: Int) -> Int? {
        guard !removed.contains(old) else { return nil }
        var row = old - removed.count(in: 0..<old)
        // Each insert at or above the row's place pushes it down one.
        for at in inserted {
            if at <= row { row += 1 } else { break }
        }
        return row
    }
}

/// Ids kept in the order of a unique key, changed in batches. A batch costs O(k log n) searches
/// plus moving small values, for k changed ids; nothing is sorted or compared per read, and each
/// batch reports exactly which rows moved (``FeedRowChanges``). Keys must be unique (put the id in
/// the key to break ties).
public nonisolated struct FeedOrderedIndex<ID: Hashable & Sendable, Key: Comparable & Sendable>: Sendable {
    public private(set) var ids: [ID] = []
    private var keys: [Key] = []
    private var keyOf: [ID: Key] = [:]

    public init() {}

    public var count: Int { ids.count }

    public func contains(_ id: ID) -> Bool { keyOf[id] != nil }

    /// The id's row, by binary search on its key.
    public func position(of id: ID) -> Int? {
        guard let key = keyOf[id] else { return nil }
        let at = lowerBound(key)
        return at < keys.count && keys[at] == key ? at : nil
    }

    /// The first row whose key is not less than `key`.
    public func lowerBound(_ key: Key) -> Int {
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Applies one batch: each id's new key (nil: not a member). `changed` names ids whose value
    /// changed even where their key did not (their rows are reported `updated`).
    public mutating func apply(_ batch: [ID: Key?], changed: Set<ID> = []) -> FeedRowChanges {
        var moving: [(id: ID, old: Key?, new: Key?)] = []
        var staying: [ID] = []
        for (id, new) in batch {
            let old = keyOf[id]
            if old == new {
                if old != nil, changed.contains(id) { staying.append(id) }
            } else {
                moving.append((id, old, new))
            }
        }
        // A batch that moves a large share of the list (a snapshot) is cheaper rebuilt by one sort
        // than inserted id by id; it reports a full reload (every old row out, every row in).
        if moving.count > 64, moving.count * 4 > ids.count {
            let before = ids.count
            for move in moving { keyOf[move.id] = move.new }
            let sorted = keyOf.sorted { $0.value < $1.value }
            ids = sorted.map(\.key)
            keys = sorted.map(\.value)
            return FeedRowChanges(removed: IndexSet(integersIn: 0..<before), inserted: IndexSet(integersIn: 0..<ids.count))
        }
        var changes = FeedRowChanges()
        // Removals, from the bottom up, at their positions before the batch.
        let removals = moving.compactMap { move in move.old.flatMap { _ in position(of: move.id) } }.sorted(by: >)
        for at in removals {
            changes.removed.insert(at)
            ids.remove(at: at)
            keys.remove(at: at)
        }
        for move in moving {
            keyOf[move.id] = move.new
        }
        for move in moving {
            guard let key = move.new else { continue }
            let at = lowerBound(key)
            ids.insert(move.id, at: at)
            keys.insert(key, at: at)
        }
        // Final positions, once every insert has landed.
        for move in moving where move.new != nil {
            if let at = position(of: move.id) { changes.inserted.insert(at) }
        }
        for id in staying {
            if let at = position(of: id) { changes.updated.insert(at) }
        }
        return changes
    }

    /// Empties the index; the caller reloads its rows.
    public mutating func removeAll() {
        ids.removeAll()
        keys.removeAll()
        keyOf.removeAll()
    }
}

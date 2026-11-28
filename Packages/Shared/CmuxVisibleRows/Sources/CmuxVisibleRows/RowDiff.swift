/// What one list update does to the rows a table shows, worked out from each row's stable id with no view: rows that
/// left are removed, new rows inserted, kept rows whose value changed reloaded, and unchanged rows left alone. A
/// table applies it (macOS `TableRows`: `removeRows`, `insertRows`, `reloadData(forRowIndexes:)`); a whole reload
/// only when no row is kept or more than `limit` rows come and go.
public enum RowDiff: Equatable, Sendable {
    /// No row kept, or too many coming and going: reload the table whole.
    case reloadAll
    /// Old offsets removed, new offsets inserted (both ascending), and new offsets of kept rows whose value changed.
    case update(removed: [Int], inserted: [Int], changed: [Int])

    /// The diff from `old` to `new`, rows matched by `id`. It compares every row once (the `itemsWalked` the meter
    /// counts): the caller hands over whole lists.
    public static func between<Row: Equatable, ID: Hashable>(_ old: [Row], _ new: [Row], id: (Row) -> ID,
                                                             limit: Int) -> RowDiff {
        let oldIDs = old.map(id), newIDs = new.map(id)
        if oldIDs == newIDs {
            return .update(removed: [], inserted: [], changed: new.indices.filter { old[$0] != new[$0] })
        }
        let kept = Set(oldIDs)
        let added = newIDs.reduce(0) { kept.contains($1) ? $0 : $0 + 1 }
        let shared = new.count - added
        guard shared > 0, added + (old.count - shared) <= limit else { return .reloadAll }
        var removed: [Int] = [], inserted: [Int] = []
        for change in newIDs.difference(from: oldIDs) {
            switch change {
            case .remove(let offset, _, _): removed.append(offset)
            case .insert(let offset, _, _): inserted.append(offset)
            }
        }
        removed.sort()
        inserted.sort()
        // Kept rows keep their order: pair them up and report the ones whose value changed.
        var changed: [Int] = []
        var oldIndex = 0, nextRemoved = 0, nextInserted = 0
        for newIndex in new.indices {
            if nextInserted < inserted.count, inserted[nextInserted] == newIndex {
                nextInserted += 1
                continue
            }
            while nextRemoved < removed.count, removed[nextRemoved] == oldIndex {
                nextRemoved += 1
                oldIndex += 1
            }
            if old[oldIndex] != new[newIndex] { changed.append(newIndex) }
            oldIndex += 1
        }
        return .update(removed: removed, inserted: inserted, changed: changed)
    }
}

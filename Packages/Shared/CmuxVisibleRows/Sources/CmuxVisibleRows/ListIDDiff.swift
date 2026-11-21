/// How a list moves from one order of row ids to the next, for a list that applies new rows in place instead of
/// reloading them all (the macOS palette's results, `PaletteListView.setSections`). Rows whose id is in both stay
/// put when they keep their relative order (the longest run of them in order) and move otherwise (a removal and an
/// insertion); the rest are removed or inserted. The common prefix and suffix are matched by position, unhashed, so
/// a change in the middle of 10,000 rows reads only the rows that changed.
public struct ListIDDiff: Equatable, Sendable {
    /// Old row indexes to remove, ascending (moved rows included).
    public var removed: [Int]
    /// New row indexes to insert, ascending (moved rows included).
    public var inserted: [Int]
    /// Kept rows that move: in `removed` and `inserted` both.
    public var moved: Int
    /// Ids hashed to match the rows between the common prefix and suffix (old and new).
    public var hashed: Int
    /// Ids compared by position, unhashed, to find the common prefix and suffix.
    public var compared: Int
    /// The old index of each new row that stays put, by new index; -1 for an inserted (or moved) row.
    public var oldIndex: [Int]

    /// The diff from `old` to `new`; nil when an id repeats where rows changed (the caller reloads) or no row is kept.
    public static func between<ID: Hashable>(_ old: [ID], _ new: [ID]) -> ListIDDiff? {
        guard !old.isEmpty, !new.isEmpty else { return nil }
        var prefix = 0
        let shorter = min(old.count, new.count)
        while prefix < shorter, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = prefix..<(old.count - suffix)
        let newMiddle = prefix..<(new.count - suffix)

        var oldIndex = [Int](repeating: -1, count: new.count)
        for i in 0..<prefix { oldIndex[i] = i }
        for k in 0..<suffix { oldIndex[new.count - 1 - k] = old.count - 1 - k }

        var oldByID: [ID: Int] = [:]
        oldByID.reserveCapacity(oldMiddle.count)
        for i in oldMiddle {
            guard oldByID.updateValue(i, forKey: old[i]) == nil else { return nil }
        }
        var keptNew: [Int] = []
        var keptOld: [Int] = []
        var seen = Set<ID>(minimumCapacity: newMiddle.count)
        for i in newMiddle {
            guard seen.insert(new[i]).inserted else { return nil }
            if let o = oldByID[new[i]] {
                keptNew.append(i)
                keptOld.append(o)
            }
        }
        guard prefix + suffix + keptOld.count > 0 else { return nil }
        var stays = [Bool](repeating: false, count: keptOld.count)
        for k in longestIncreasingRun(keptOld) {
            stays[k] = true
            oldIndex[keptNew[k]] = keptOld[k]
        }
        var keptOldSet = [Bool](repeating: false, count: oldMiddle.count)
        for (k, o) in keptOld.enumerated() where stays[k] { keptOldSet[o - prefix] = true }
        let removed = oldMiddle.filter { !keptOldSet[$0 - prefix] }
        let inserted = newMiddle.filter { oldIndex[$0] < 0 }
        return ListIDDiff(removed: removed, inserted: inserted, moved: stays.count { !$0 },
                          hashed: oldMiddle.count + newMiddle.count, compared: prefix + suffix, oldIndex: oldIndex)
    }

    /// Of `rows` (new indexes: the rows a list holds views for), the kept ones whose content changed, ascending:
    /// the rows to configure again. Inserted rows are configured by their insertion.
    public func rowsToReconfigure(_ rows: some Sequence<Int>, changed: (_ old: Int, _ new: Int) -> Bool) -> [Int] {
        rows.filter { $0 >= 0 && $0 < oldIndex.count && oldIndex[$0] >= 0 && changed(oldIndex[$0], $0) }.sorted()
    }

    /// Indexes into `values` of one longest strictly increasing subsequence.
    public static func longestIncreasingRun(_ values: [Int]) -> [Int] {
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: values.count)
        for (i, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var run: [Int] = []
        var i = tails.last ?? -1
        while i >= 0 {
            run.append(i)
            i = previous[i]
        }
        return run.reversed()
    }
}

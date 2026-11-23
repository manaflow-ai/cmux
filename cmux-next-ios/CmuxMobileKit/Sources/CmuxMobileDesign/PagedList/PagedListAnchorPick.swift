#if os(iOS)
/// Which of the anchored rows the list puts back after an update (``PagedListController``'s restore):
/// each anchored row still in the list, in anchor order (the row being read first), with its index
/// before and after the update. Returns the position (in `rows`) of the row to keep still, or nil.
enum PagedListAnchorPick {
    struct Row {
        var oldIndex: Int
        var newIndex: Int
    }

    /// The rows in place are the longest run that kept its order: sorted by where they were, their
    /// new places rise along it (on a tie, the run that ends later, so a read row that may have moved
    /// is not preferred). The first anchored row in place is kept: the row being read when it kept
    /// its place, whatever arrived or left next to it (rows inserted right under it no longer make it
    /// skipped); a row moved elsewhere (moveToNewest, a re-sort) is never kept.
    static func pick(_ rows: [Row]) -> Int? {
        guard !rows.isEmpty else { return nil }
        let order = rows.indices.sorted { rows[$0].oldIndex < rows[$1].oldIndex }
        var length = [Int](repeating: 1, count: order.count)
        var before = [Int](repeating: -1, count: order.count)
        for a in order.indices {
            for b in 0 ..< a where rows[order[b]].newIndex < rows[order[a]].newIndex && length[b] + 1 > length[a] {
                length[a] = length[b] + 1
                before[a] = b
            }
        }
        var end = 0
        for a in order.indices where length[a] >= length[end] { end = a }
        var inPlace = Set<Int>()
        var a = end
        while a >= 0 {
            inPlace.insert(order[a])
            a = before[a]
        }
        return rows.indices.first { inPlace.contains($0) }
    }
}
#endif

#if os(iOS)
/// Which of the anchored rows the list puts back after an update (``PagedListController``'s restore):
/// each anchored row still in the list, with its index before and after the update, in the order the
/// restore tries them (``candidates(count:reading:straddles:)``). Returns the position (in `rows`) of
/// the row to keep still, or nil.
enum PagedListAnchorPick {
    struct Row {
        var oldIndex: Int
        var newIndex: Int
    }

    /// The order in which the restore tries the anchored rows, as positions in the anchor (top to bottom
    /// on screen, or lowest first for an anchor read from the bottom).
    ///
    /// `reading` is the row being read when the list was last laid out (the frame the reader saw): it
    /// comes first, then the rows after it, then those before it, nearest first. A fling carries that
    /// row a few points past the top edge between the frame that drew it and an update landing; it is
    /// still the row the reader was looking at, and the one the frame-shift measure follows. Passing it
    /// over as a row cut by the top edge kept the row under it still instead, so rows inserted right
    /// under it moved it by their own height (one-row shifts of 126-146 pt in the insert and flood cases,
    /// steps bd734f10 and 0b7d601b).
    ///
    /// Without it, every row in order, less the first when it is cut by the top edge (`straddles`): a
    /// cut row that changes height then keeps the rows below it still (d20b5519).
    static func candidates(count: Int, reading: Int?, straddles: Bool) -> [Int] {
        guard count > 0 else { return [] }
        if let reading, reading >= 0, reading < count {
            return Array(reading ..< count) + Array((0 ..< reading).reversed())
        }
        return Array((straddles && count > 1 ? 1 : 0) ..< count)
    }

    /// The rows in place: the longest run that kept its order (sorted by where they were, their new
    /// places rise along it; on a tie, the run that ends later, so a read row that may have moved is
    /// not preferred). A row moved elsewhere (moveToNewest, a re-sort) is never in place.
    static func inPlace(_ rows: [Row]) -> Set<Int> {
        guard !rows.isEmpty else { return [] }
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
        return inPlace
    }

    /// The row to keep still: the first of `rows` (in the restore's order) that is in place, whatever
    /// arrived, left or changed height next to it. A row moved elsewhere is never kept.
    ///
    /// Not the in-place row that moved least on screen (the rule of 23f9d387, with its guard): a row
    /// under an insert, a removal or a grown row moves on screen by design, so that rule kept a row
    /// further down still and moved the row being read instead, by 40-444 pt under inserts, the flood
    /// and a resting finger (step 0b7d601b, 26 of 30 cases red), and a second restore in the same update
    /// could pick another row and undo the first (`g0+299 ... g0-299`, down-resting-inserts).
    static func pick(_ rows: [Row]) -> Int? {
        let inPlace = inPlace(rows)
        return rows.indices.first { inPlace.contains($0) }
    }
}
#endif

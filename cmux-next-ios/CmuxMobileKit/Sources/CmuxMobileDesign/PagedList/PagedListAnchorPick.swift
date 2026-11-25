#if os(iOS)
import CoreGraphics

/// Which of the anchored rows the list puts back after an update (``PagedListController``'s restore):
/// each anchored row still in the list, in anchor order (the row being read first), with its index
/// before and after the update. Returns the position (in `rows`) of the row to keep still, or nil.
enum PagedListAnchorPick {
    struct Row {
        var oldIndex: Int
        var newIndex: Int
        /// How far the row moved on screen in the update (pt), at the anchor's own point (top, or
        /// bottom for an anchor read from the bottom): where it is now less where the anchor held it.
        var moved: CGFloat = 0
    }

    /// The rows in place are the longest run that kept its order: sorted by where they were, their
    /// new places rise along it (on a tie, the run that ends later, so a read row that may have moved
    /// is not preferred). The first anchored row in place is kept: the row being read when it kept
    /// its place, whatever arrived or left next to it (rows inserted right under it no longer make it
    /// skipped); a row moved elsewhere (moveToNewest, a re-sort) is never kept.
    /// The guard on a pick (inside an update): a correction larger than the update's own offset move
    /// plus its rows' size changes means the pick left its place. Then the row to keep instead is
    /// another row IN PLACE that moved least, never a row the run excluded (the reader included: it
    /// may have moved far, 6c578603: falling back to it shifted 45,969 pt). nil keeps the pick.
    static func guarded(_ rows: [Row], pick: Int, updateMove: CGFloat, sized: CGFloat) -> Int? {
        guard rows.indices.contains(pick), abs(rows[pick].moved) > abs(updateMove) + abs(sized) + 0.5 else { return nil }
        let inPlace = inPlace(rows)
        let others = rows.indices.filter { $0 != pick && inPlace.contains($0) && abs(rows[$0].moved) < abs(rows[pick].moved) }
        return others.min { abs(rows[$0].moved) < abs(rows[$1].moved) }
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

    /// The row to keep still. B's rule: the first anchored row in place (the row being read when it
    /// kept its place, whatever arrived or left next to it). When indices moved in the update (rows
    /// came, went or moved), of the rows in place the one that moved least on screen: a row the load
    /// moved can stay in order with one or two others during a fling, but it travelled. When no index
    /// moved (edits only) B's rule stands: every row under a grown row moves on screen by design.
    static func pick(_ rows: [Row]) -> Int? {
        let inPlace = inPlace(rows)
        guard !inPlace.isEmpty else { return nil }
        let candidates = rows.indices.filter { inPlace.contains($0) }
        let indicesMoved = rows.contains { $0.oldIndex != $0.newIndex }
        guard indicesMoved else { return candidates.first }
        return candidates.min { a, b in
            let ma = abs(rows[a].moved), mb = abs(rows[b].moved)
            return ma != mb ? ma < mb : a < b
        }
    }
}
#endif

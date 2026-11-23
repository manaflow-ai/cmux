#if os(iOS)
/// Which of the anchored rows the list puts back after an update (``PagedListController``'s restore):
/// each anchored row still in the list, in anchor order (the row being read first), with its index
/// before and after the update. Returns the position (in `rows`) of the row to keep still, or nil.
enum PagedListAnchorPick {
    struct Row {
        var oldIndex: Int
        var newIndex: Int
    }

    static func pick(_ rows: [Row]) -> Int? {
        guard !rows.isEmpty else { return nil }
        // A row kept its place when the gap to its neighbour (the next anchored row, or the one
        // before for the last) changed by at most max(2, the gap) and kept its sign.
        func stable(_ i: Int) -> Bool {
            guard rows.count > 1 else { return true }
            let j = i + 1 < rows.count ? i + 1 : i - 1
            let oldGap = rows[j].oldIndex - rows[i].oldIndex
            let newGap = rows[j].newIndex - rows[i].newIndex
            return oldGap.signum() == newGap.signum() && abs(newGap - oldGap) <= max(2, abs(oldGap))
        }
        return rows.indices.first(where: stable)
    }
}
#endif

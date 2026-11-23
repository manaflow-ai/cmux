#if os(iOS)
import CoreGraphics

/// Which row the frame-shift measures follow from one committed frame to the next, and how far it
/// moved (DEBUG measure only; the app never sets a probe). `previous` and `current` are the rows on
/// screen in each frame, in screen order, each with its place in the window (top, or bottom for an
/// `.up` list at its newest row); `reading` is the row read in the previous frame.
enum PagedListFollow {
    struct Row<ID: Hashable> {
        var id: ID
        var y: CGFloat
    }

    /// The row followed and its place in both frames; nil when no row can be followed.
    ///
    /// Only a row that kept its place among the others counts: the rows in both frames, in the
    /// previous frame's order, of which the longest run still in the same order now are the ones in
    /// place; a row outside it moved within the list (a re-sort, the load's moveToNewest, the row
    /// read going to the newest end) and its trip is not a shift. The row being read when it is in
    /// place, else the first row in place. A row that arrives or goes next to the one read changes
    /// nothing in place, so a jump drawn in that frame still counts in full.
    static func pick<ID: Hashable>(previous: [Row<ID>], current: [Row<ID>], reading: ID?) -> (id: ID, was: CGFloat, now: CGFloat)? {
        var rank: [ID: Int] = [:]
        for (i, row) in current.enumerated() where rank[row.id] == nil { rank[row.id] = i }
        let both = previous.compactMap { row in rank[row.id].map { (row: row, rank: $0) } }
        guard !both.isEmpty else { return nil }
        // The longest run of rows whose places now rise in the previous order (n is a screenful).
        var length = [Int](repeating: 1, count: both.count)
        var before = [Int](repeating: -1, count: both.count)
        for i in both.indices {
            for j in 0 ..< i where both[j].rank < both[i].rank && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                before[i] = j
            }
        }
        var end = 0
        for i in both.indices where length[i] > length[end] { end = i }
        var inPlace = Set<ID>()
        var i = end
        while i >= 0 {
            inPlace.insert(both[i].row.id)
            i = before[i]
        }
        let followed = both.first { $0.row.id == reading && inPlace.contains($0.row.id) }
            ?? both.first { inPlace.contains($0.row.id) }
        guard let followed else { return nil }
        return (followed.row.id, followed.row.y, current[followed.rank].y)
    }
}
#endif

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
    /// place, else the row in place drawn nearest where the read row was (what the reader was
    /// looking at; on a tie, the one below it). A row that arrives or goes next to the one read
    /// changes nothing in place, so a jump drawn in that frame still counts in full.
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
        let candidates = both.filter { inPlace.contains($0.row.id) }
        let followed: (row: Row<ID>, rank: Int)?
        if let read = candidates.first(where: { $0.row.id == reading }) {
            followed = read
        } else if let eye = previous.first(where: { $0.id == reading })?.y {
            followed = candidates.min { a, b in
                let da = abs(a.row.y - eye), db = abs(b.row.y - eye)
                return da != db ? da < db : a.row.y > b.row.y
            }
        } else {
            followed = candidates.first
        }
        guard let followed else { return nil }
        return (followed.row.id, followed.row.y, current[followed.rank].y)
    }

    /// A row as drawn, with its height (the neighbour measure).
    struct Drawn<ID: Hashable> {
        var id: ID
        var y: CGFloat
        var height: CGFloat
    }

    /// The neighbour measure: how far the rows around the eye line moved on screen beyond what the
    /// scroll explains, independent of the row either measure follows or the anchor keeps still.
    /// The neighbours are up to `around` rows on each side of the row read last frame, in the
    /// previous frame's screen order. A neighbour counts only when nothing between it and the read
    /// row changed: the same rows in the same order in both frames, none resized, the neighbour
    /// itself not resized (an arrival, a removal or a row that grew between them moves it by
    /// design). Returns the largest such move (signed) and its row, or nil when none counts.
    static func neighbourShift<ID: Hashable>(previous: [Drawn<ID>], current: [Drawn<ID>], reading: ID?, explained: CGFloat,
                                             around: Int = 2) -> (id: ID, shift: CGFloat)? {
        guard let reading, let r = previous.firstIndex(where: { $0.id == reading }) else { return nil }
        var now: [ID: (index: Int, row: Drawn<ID>)] = [:]
        for (i, row) in current.enumerated() where now[row.id] == nil { now[row.id] = (i, row) }
        guard now[reading] != nil else { return nil }
        func same(_ a: Drawn<ID>) -> Bool {
            guard let b = now[a.id]?.row else { return false }
            return abs(a.height - b.height) <= 0.5
        }
        var worst: (id: ID, shift: CGFloat)?
        let low = max(0, r - around), high = min(previous.count - 1, r + around)
        for k in low ... high where k != r {
            let span = k < r ? Array(previous[k ... r]) : Array(previous[r ... k])
            guard span.allSatisfy(same) else { continue }
            // The same rows between them now, adjacent in the same order.
            let indices = span.compactMap { now[$0.id]?.index }
            guard indices.count == span.count, zip(indices, indices.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { continue }
            let was = previous[k]
            guard let current = now[was.id]?.row else { continue }
            let shift = (current.y - was.y) + explained
            if worst == nil || abs(shift) > abs(worst!.shift) { worst = (was.id, shift) }
        }
        return worst
    }
}
#endif

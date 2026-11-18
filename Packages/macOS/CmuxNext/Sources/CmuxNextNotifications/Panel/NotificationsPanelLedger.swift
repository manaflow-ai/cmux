import CoreGraphics
import Foundation

/// The panel's rows newest first, each id's index and each row's top: what a ledger delta
/// (`list-notifications` `since`) updates in O(changed). An index is a key less `base`, and a top is an
/// offset less `offsets[0]`, so a row added at the top or taken from the bottom (a new notification, an
/// eviction) moves no other row's entry; a change in the middle updates the shorter side.
struct NotificationsPanelLedger {
    private(set) var rows: [NotificationsPanelRow] = []
    private var keys: [String: Int] = [:]
    private var base = 0
    /// Row edges: row `i` spans `offsets[i]..<offsets[i + 1]`, less `offsets[0]`.
    private var offsets: [CGFloat] = [0]
    private(set) var unreadCount = 0

    var count: Int { rows.count }
    var height: CGFloat { offsets[rows.count] - offsets[0] }

    func index(of id: String) -> Int? { keys[id].map { $0 - base } }
    func top(_ index: Int) -> CGFloat { offsets[index] - offsets[0] }
    func rowHeight(_ index: Int) -> CGFloat { offsets[index + 1] - offsets[index] }

    /// Every row anew, `heights[i]` tall.
    mutating func replace(_ rows: [NotificationsPanelRow], heights: [CGFloat]) {
        self.rows = rows
        base = 0
        keys = [:]
        keys.reserveCapacity(rows.count)
        offsets = [0]
        offsets.reserveCapacity(rows.count + 1)
        for (index, row) in rows.enumerated() {
            keys[row.id] = index
            offsets.append(offsets[index] + heights[index])
        }
        unreadCount = rows.reduce(0) { $0 + ($1.unread ? 1 : 0) }
    }

    /// The row at `index` becomes `row` (the same id), `height` tall.
    mutating func update(at index: Int, _ row: NotificationsPanelRow, height: CGFloat) {
        unreadCount += (row.unread ? 1 : 0) - (rows[index].unread ? 1 : 0)
        rows[index] = row
        let delta = height - rowHeight(index)
        guard delta != 0 else { return }
        if index < rows.count - 1 - index {
            for edge in 0...index { offsets[edge] -= delta }
        } else {
            for edge in (index + 1)...rows.count { offsets[edge] += delta }
        }
    }

    /// Where a new row goes: before the first row not newer than it (a tie: the daemon's newer row first).
    func insertionIndex(_ row: NotificationsPanelRow) -> Int {
        var low = 0, high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].createdAt > row.createdAt { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Adds `row`, `height` tall, at `index`.
    mutating func insert(_ row: NotificationsPanelRow, at index: Int, height: CGFloat) {
        rows.insert(row, at: index)
        offsets.insert(offsets[index], at: index)
        unreadCount += row.unread ? 1 : 0
        if index < rows.count - index {
            // The rows above keep their index and move up.
            base -= 1
            for above in 0..<index { keys[rows[above].id] = above + base }
            for edge in 0...index { offsets[edge] -= height }
        } else {
            for below in (index + 1)..<rows.count { keys[rows[below].id] = below + base }
            for edge in (index + 1)...rows.count { offsets[edge] += height }
        }
        keys[row.id] = index + base
    }

    /// Takes away the row at `index`.
    mutating func remove(at index: Int) {
        let height = rowHeight(index)
        let row = rows.remove(at: index)
        keys[row.id] = nil
        unreadCount -= row.unread ? 1 : 0
        if index < rows.count - index {
            // The rows above keep their index and move down.
            base += 1
            for above in 0..<index { keys[rows[above].id] = above + base }
            for edge in 0...index { offsets[edge] += height }
            offsets.remove(at: index)
        } else {
            for below in index..<rows.count { keys[rows[below].id] = below + base }
            for edge in (index + 1)..<offsets.count { offsets[edge] -= height }
            offsets.remove(at: index + 1)
        }
    }
}

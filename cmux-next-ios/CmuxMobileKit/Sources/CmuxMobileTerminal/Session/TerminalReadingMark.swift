import CoreGraphics

/// Where the reader was before a mirror reset, so the reset's replay can put
/// them back (verifier V2-3, T-LIFE-09: a link drop while reading brought the
/// page back at the live bottom).
///
/// The replay rebuilds the scrollback from the Mac's history, which need not
/// match the phone's row for row (output during the drop appends; the Mac's
/// history can start later than the phone's did). So the anchored row is
/// found again by content, not by index:
/// 1. the anchor's own rows, exactly, at the same row and then nearest-first
///    around it (rows that arrive only append, so the reader's own row is the
///    best guess; never the distance from the end: T-LIFE-09/15);
/// 2. else every row read (the screen around the anchor, neighbours above
///    included) votes for where the window starts in the replay; the best
///    supported start wins, so a few rows that read differently in the replay
///    (a redrawn status row, a line serialized another way) or blank rows at
///    the anchor do not lose the place (round 3: 5 of 5 read-drops lost it
///    once the row counts differed);
/// 3. else the shift of the rows that were at the end;
/// 4. else the same row. The change in total rows is never applied: rows that
///    arrived during a drop pushed the reader down by their count (round 8).
/// The screen reads every row for it (`TerminalScreenRows`), so 1 and 2 reach
/// the whole replay.
struct TerminalReadingMark: Equatable {
    /// The rows read, from `rowsBefore` rows above the anchor down (text,
    /// trailing blanks trimmed).
    let rows: [String]
    /// The anchor's index in `rows`.
    let anchorIndex: Int
    let rowsFromEnd: Int
    /// The anchor's row as it was, and its pixel remainder.
    let row: Int
    let delta: CGFloat
    /// The document's last `tailLength` rows when marked (oldest first), and
    /// the total then: rows the replay still has near its end, readable
    /// when the anchor's rows are not (round 8, V2-3 residual).
    let tail: [String]
    let totalRows: Int

    /// Rows of the exact match at the anchor.
    static let length = 6
    /// Neighbours kept above the anchor, and rows from the anchor down (a screen).
    static let rowsBefore = 8
    static let rowsAfter = 48
    /// How far from the expected row the text is searched (rows).
    static let searchRows = 2000
    /// A text that repeats more than this in the window does not vote.
    static let maxRepeats = 3
    /// Rows kept from the document's end.
    static let tailLength = 40

    /// Nil when the rows read are all blank (nothing to find them by) or
    /// cannot be read.
    init?(anchor: TerminalScrollModel.Anchor, totalRows: Int, rowText: (Int) -> String?) {
        guard anchor.row >= 0, anchor.row < totalRows else { return nil }
        let first = max(0, anchor.row - Self.rowsBefore)
        var rows: [String] = []
        for row in first..<min(totalRows, anchor.row + Self.rowsAfter) {
            guard let text = rowText(row) else { return nil }
            rows.append(Self.normalized(text))
        }
        guard rows.contains(where: { !$0.isEmpty }) else { return nil }
        self.rows = rows
        self.anchorIndex = anchor.row - first
        self.rowsFromEnd = totalRows - anchor.row
        self.row = anchor.row
        self.delta = anchor.delta
        self.totalRows = totalRows
        let tailStart = max(0, totalRows - Self.tailLength)
        self.tail = (tailStart..<totalRows).map { rowText($0).map(Self.normalized) ?? "" }
    }

    /// The anchor in a rebuilt scrollback of `totalRows` rows.
    func locate(totalRows: Int, rowText: (Int) -> String?) -> TerminalScrollModel.Anchor? {
        guard totalRows > 0 else { return nil }
        let center = min(max(0, row), totalRows - 1)
        var cache: [Int: String] = [:]
        func text(_ row: Int) -> String? {
            if let hit = cache[row] { return hit }
            let value = rowText(row).map(Self.normalized)
            if let value { cache[row] = value }
            return value
        }
        // 1. The anchor's rows, exactly (when they have text).
        let head = Array(rows[anchorIndex..<min(rows.count, anchorIndex + Self.length)])
        if head.contains(where: { !$0.isEmpty }) {
            func matches(_ start: Int) -> Bool {
                guard start >= 0, start + head.count <= totalRows else { return false }
                for (index, expected) in head.enumerated() where text(start + index) != expected { return false }
                return true
            }
            if matches(row) { return .init(row: row, delta: delta) }
            for distance in 0...Self.searchRows {
                for candidate in distance == 0 ? [center] : [center - distance, center + distance] where matches(candidate) {
                    return .init(row: candidate, delta: delta)
                }
            }
        }
        // 2. Every distinctive row read votes for the window's start.
        var positions: [String: [Int]] = [:]
        for (index, value) in rows.enumerated() where !value.isEmpty { positions[value, default: []].append(index) }
        positions = positions.filter { $0.value.count <= Self.maxRepeats }
        let voters = positions.values.reduce(0) { $0 + $1.count }
        if voters > 0 {
            let expectedStart = center - anchorIndex
            let low = max(0, expectedStart - Self.searchRows)
            let high = min(totalRows - 1, expectedStart + Self.searchRows + rows.count)
            var votes: [Int: Int] = [:]
            if low <= high {
                for row in low...high {
                    guard let value = text(row), let indices = positions[value] else { continue }
                    for index in indices { votes[row - index, default: 0] += 1 }
                }
            }
            let needed = max(2, Int((Double(voters) * 0.4).rounded(.up)))
            let best = votes.filter { $0.value >= needed }.max { a, b in
                a.value != b.value ? a.value < b.value : abs(a.key - expectedStart) > abs(b.key - expectedStart)
            }
            if let best {
                let anchor = min(max(0, best.key + anchorIndex), totalRows - 1)
                return .init(row: anchor, delta: delta)
            }
        }
        // 3. The rows that were at the end: where they are now gives the shift
        // of every row above them (output during the drop moved the end).
        if let shift = tailShift(totalRows: totalRows, text: text) {
            let anchor = min(max(0, row + shift), totalRows - 1)
            return .init(row: anchor, delta: delta)
        }
        // 4. The same row.
        return .init(row: center, delta: delta)
    }

    /// The shift (new row - old row) most of the distinctive tail rows agree
    /// on, searching the new end's last `searchRows` rows.
    private func tailShift(totalRows: Int, text: (Int) -> String?) -> Int? {
        let tailStart = self.totalRows - tail.count
        var positions: [String: [Int]] = [:]
        for (index, value) in tail.enumerated() where !value.isEmpty { positions[value, default: []].append(tailStart + index) }
        positions = positions.filter { $0.value.count <= Self.maxRepeats }
        let voters = positions.values.reduce(0) { $0 + $1.count }
        guard voters >= 3 else { return nil }
        var votes: [Int: Int] = [:]
        for newRow in stride(from: totalRows - 1, through: max(0, totalRows - Self.searchRows), by: -1) {
            guard let value = text(newRow), let olds = positions[value] else { continue }
            for old in olds { votes[newRow - old, default: 0] += 1 }
        }
        let needed = max(3, Int((Double(voters) * 0.4).rounded(.up)))
        let best = votes.filter { $0.value >= needed }.max { a, b in a.value != b.value ? a.value < b.value : abs(a.key) > abs(b.key) }
        return best?.key
    }

    private static func normalized(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last == " " || last == "\n" || last == "\r" || last == "\t" { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}

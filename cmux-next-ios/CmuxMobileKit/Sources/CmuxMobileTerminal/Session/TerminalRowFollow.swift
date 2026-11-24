/// Where a highlight's rows went when a full-screen app redrew its screen
/// (Leo, 2026-11-24: "sometimes the highlights in terminal just float and dont
/// move when i scroll?").
///
/// A full-screen app (vim, htop, Claude Code's full-screen mode) has no
/// scrollback: the phone addresses its cells as viewport rows, and when the
/// app scrolls (the finger's wheel, the Mac's, new output) it draws its text
/// on other rows. A highlight held as viewport rows then stays where it was,
/// over whatever text came there. This finds the rows' text again on the new
/// screen so the highlight moves with it, or says it is gone.
public enum TerminalRowFollow {
    /// The rows `selected` (the text of rows `firstRow...`, as read when the
    /// highlight was made) moved by this many rows on `screen` (row 0 = the
    /// top): 0 when they are still in place, nil when they are no longer on
    /// the screen whole. The nearest match wins. Trailing blanks never count
    /// (a redraw may pad a row with spaces), and rows that read blank match
    /// any row; a highlight over blank rows only stays where it is.
    public static func delta(selected: [String], firstRow: Int, screen: [String]) -> Int? {
        let wanted = selected.map(trimmed)
        guard wanted.contains(where: { !$0.isEmpty }) else { return 0 }
        let rows = screen.map(trimmed)
        let span = wanted.count
        guard span <= rows.count else { return nil }
        // Every top row the selection fits at, nearest to where it was first.
        let tops = 0...(rows.count - span)
        let order = tops.sorted { abs($0 - firstRow) == abs($1 - firstRow) ? $0 < $1 : abs($0 - firstRow) < abs($1 - firstRow) }
        for top in order where matches(wanted, at: top, in: rows) {
            return top - firstRow
        }
        return nil
    }

    private static func matches(_ wanted: [String], at top: Int, in rows: [String]) -> Bool {
        for (offset, text) in wanted.enumerated() where !text.isEmpty && rows[top + offset] != text {
            return false
        }
        return true
    }

    private static func trimmed(_ row: String) -> String {
        var row = Substring(row)
        while let last = row.last, last == " " || last == "\u{0}" { row.removeLast() }
        return String(row)
    }
}

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

    /// What became of a highlight's rows on a redrawn screen.
    public enum Outcome: Equatable {
        /// Its text is on the screen, this many rows away (0: in place).
        case moved(Int)
        /// Its rows were rewritten where they are (htop's numbers, a spinner, a streamed line,
        /// Copy Mode's cursor cell): the rows around it did not move, so the highlight stays.
        case rewritten
        /// Its text moved or scrolled off the screen.
        case gone
    }

    /// Where a highlight's rows went on the redrawn screen. `above` and `below` are the rows
    /// just outside it as they read when it was read (nil past the screen's edge).
    ///
    /// - Its text is on the screen once: ``Outcome/moved(_:)`` there.
    /// - On several rows (a lone "│" or "---" row repeats): the copy whose neighbours still
    ///   read the same, or the one in place among those; with no single answer it is
    ///   ``Outcome/gone``, never a guess that puts the highlight on another copy.
    /// - Not on the screen: ``Outcome/rewritten`` when its rows were rewritten where they are
    ///   (they are not blank, and the neighbours with text still read the same where they
    ///   were), else ``Outcome/gone``. With no neighbour with text to go by, or rows that went
    ///   blank (a screen cleared before it is drawn again), it is gone.
    public static func follow(selected: [String], above: String?, below: String?,
                              firstRow: Int, screen: [String]) -> Outcome {
        let wanted = selected.map(trimmed)
        let rows = screen.map(trimmed)
        let span = wanted.count
        guard span > 0, span <= rows.count else { return .gone }
        guard wanted.contains(where: { !$0.isEmpty }) else { return .moved(0) }
        let neighbours = [(-1, above.map(trimmed)), (span, below.map(trimmed))]
            .compactMap { offset, text in text.flatMap { $0.isEmpty ? nil : (offset, $0) } }
        /// The neighbours with text read the same around `top`.
        func vouched(_ top: Int) -> Bool {
            neighbours.allSatisfy { offset, text in rows.indices.contains(top + offset) && rows[top + offset] == text }
        }
        let tops = (0...(rows.count - span)).filter { matches(wanted, at: $0, in: rows) }
        if tops.count == 1 { return .moved(tops[0] - firstRow) }
        if tops.count > 1 {
            let sure = tops.filter(vouched)
            if sure.count == 1 { return .moved(sure[0] - firstRow) }
            if sure.contains(firstRow) || (sure.isEmpty && neighbours.isEmpty && tops.contains(firstRow)) { return .moved(0) }
            return .gone
        }
        guard firstRow >= 0, firstRow + span <= rows.count,
              rows[firstRow..<(firstRow + span)].contains(where: { !$0.isEmpty }),
              !neighbours.isEmpty, vouched(firstRow) else { return .gone }
        return .rewritten
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

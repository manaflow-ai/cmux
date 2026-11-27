/// One terminal cell: an absolute row (0 = the oldest scrollback row, Ghostty's
/// `GHOSTTY_POINT_SCREEN` y) and a column.
public struct TerminalCellPoint: Comparable, Hashable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// A text selection over the terminal's rows, scrollback included (G-14,
/// T-SEL-01/02). Like iOS text: a long press selects the word under the
/// finger, two handles move either end (a handle dragged past the other
/// swaps them), Select All takes the whole document. Both ends are inclusive.
public struct TerminalTextSelection: Equatable, Sendable {
    public enum Handle: Sendable { case start, end }

    /// The end that stays when the other handle moves.
    public var anchor: TerminalCellPoint
    public var head: TerminalCellPoint

    public init(anchor: TerminalCellPoint, head: TerminalCellPoint) {
        self.anchor = anchor
        self.head = head
    }

    public var start: TerminalCellPoint { min(anchor, head) }
    public var end: TerminalCellPoint { max(anchor, head) }

    /// Characters that keep a word together: paths, URLs, flags, identifiers.
    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_-./~:@%+=#?&".contains(character)
    }

    /// The word at `point` in `line` (the row's text, one character per
    /// cell), or the single cell when it is blank or past the line's end.
    public static func word(at point: TerminalCellPoint, line: String, columns: Int) -> TerminalTextSelection {
        let lastColumn = max(0, columns - 1)
        let column = min(max(0, point.column), lastColumn)
        let characters = Array(line)
        guard column < characters.count, isWordCharacter(characters[column]) else {
            let cell = TerminalCellPoint(row: point.row, column: column)
            return TerminalTextSelection(anchor: cell, head: cell)
        }
        var lower = column
        while lower > 0, isWordCharacter(characters[lower - 1]) { lower -= 1 }
        var upper = column
        while upper + 1 < characters.count, upper + 1 <= lastColumn, isWordCharacter(characters[upper + 1]) { upper += 1 }
        // A trailing sentence period or colon is not part of a path.
        while upper > lower, ".:".contains(characters[upper]) { upper -= 1 }
        return TerminalTextSelection(anchor: TerminalCellPoint(row: point.row, column: lower),
                                     head: TerminalCellPoint(row: point.row, column: upper))
    }

    /// The whole document: `originRow` to the row before `endRow`.
    public static func all(originRow: Int, endRow: Int, columns: Int) -> TerminalTextSelection {
        TerminalTextSelection(anchor: TerminalCellPoint(row: originRow, column: 0),
                              head: TerminalCellPoint(row: max(originRow, endRow - 1), column: max(0, columns - 1)))
    }

    /// Moves one handle to `point`. Past the other handle, the two swap
    /// roles, so the handle under the finger keeps moving.
    public mutating func move(_ handle: Handle, to point: TerminalCellPoint) {
        let fixed = handle == .start ? end : start
        anchor = fixed
        head = point
    }

    /// The handle under the finger after `move`: the end the head is now.
    public var headHandle: Handle { head < anchor ? .start : .end }

    /// Each selected row and its column span (for the highlight).
    public func rowSpans(columns: Int) -> [(row: Int, columns: Range<Int>)] {
        let width = max(1, columns)
        let first = start, last = end
        return (first.row...last.row).map { row in
            let lower = row == first.row ? min(first.column, width - 1) : 0
            let upper = row == last.row ? min(last.column, width - 1) + 1 : width
            return (row, lower..<max(lower + 1, upper))
        }
    }

    /// The copied text: each row's trailing blanks and the trailing empty
    /// rows dropped (Ghostty pads rows to the grid width).
    public static func cleaned(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var line = line
            while let last = line.last, last == " " || last == "\r" { line = line.dropLast() }
            return line
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// One read of the live grid for ``PredictiveEcho``: the cursor, the grid width, which screen is
/// active, and the cells of one row from ``start`` to the right margin, plus the one cell left of
/// ``start``. Every other cell is unknown (nil), which the predictor treats as not blank, so it never
/// predicts over a cell it did not read.
///
/// The cells come from Ghostty's plain text of the row (`ghostty_surface_read_text`): an empty cell
/// between two glyphs is a space, and the empty cells at the end of the row are left out. A printable
/// ASCII byte is one cell. A non-ASCII scalar has a width this cannot know (a wide glyph takes two
/// cells, a combining mark joins the cell before it), so that cell, the one before it and every later
/// cell are unknown. The cell left of ``start`` is known only when its text is one printable byte: an
/// empty cell and a wide glyph's second half both read as no text.
nonisolated struct PredictionRow: PredictionScreen, Equatable, Sendable {
    let cursorRow: Int
    let cursorColumn: Int
    let columns: Int
    let isAlternateScreen: Bool
    /// The row the cells are of.
    let row: Int
    /// The first column of ``cells``.
    let start: Int
    /// Columns `start..<columns`.
    private let cells: [UInt8?]
    /// The cell at `start - 1`.
    private let before: UInt8?

    /// - Parameters:
    ///   - text: The UTF-8 text of `row` from `start` to the right margin; nil: not read (all unknown).
    ///   - beforeText: The UTF-8 text of the one cell at `start - 1`; nil: not read.
    init(cursorRow: Int, cursorColumn: Int, columns: Int, isAlternateScreen: Bool, row: Int, start: Int,
         text: [UInt8]?, beforeText: [UInt8]?) {
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.columns = columns
        self.isAlternateScreen = isAlternateScreen
        self.row = row
        self.start = start
        let count = max(columns - start, 0)
        cells = text.map { Self.cells(of: $0, count: count) } ?? Array(repeating: nil, count: count)
        if let beforeText, beforeText.count == 1, let byte = beforeText.first, Self.isPrintable(byte) {
            before = byte
        } else {
            before = nil
        }
    }

    func glyph(row: Int, column: Int) -> UInt8? {
        guard row == self.row else { return nil }
        if column == start - 1 { return before }
        guard column >= start, column - start < cells.count else { return nil }
        return cells[column - start]
    }

    /// The `count` cells `text` shows from its first byte.
    static func cells(of text: [UInt8], count: Int) -> [UInt8?] {
        var cells = [UInt8?](repeating: PredictiveEcho.blank, count: count)
        var column = 0
        for byte in text {
            guard column < count else { break }
            guard isPrintable(byte) else {
                // A wide glyph, a combining mark (it belongs to the cell before) or a control byte.
                for index in max(column - 1, 0)..<count { cells[index] = nil }
                return cells
            }
            cells[column] = byte
            column += 1
        }
        return cells
    }

    private static func isPrintable(_ byte: UInt8) -> Bool {
        (0x20...0x7E).contains(byte)
    }
}

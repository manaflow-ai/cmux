import Foundation
import Testing

import CmuxTerminalCore

@Suite("Terminal caret accessibility grid")
struct TerminalCaretGridTests {
    private let grid = TerminalCaretGrid(rows: 10, columns: 40)!

    @Test func rejectsGridsWithoutCells() {
        #expect(TerminalCaretGrid(rows: 0, columns: 40) == nil)
        #expect(TerminalCaretGrid(rows: 10, columns: 0) == nil)
        #expect(TerminalCaretGrid(rows: -1, columns: -1) == nil)
    }

    @Test func offsetsAreRowMajorAndInvertible() {
        #expect(grid.characterCount == 400)
        #expect(grid.index(row: 0, column: 0) == 0)
        #expect(grid.index(row: 3, column: 7) == 127)
        #expect(grid.cell(forIndex: 127) == (row: 3, column: 7))
    }

    @Test func offsetsClampToTheVisibleGrid() {
        #expect(grid.index(row: 99, column: 99) == 399)
        #expect(grid.index(row: -5, column: -5) == 0)
        #expect(grid.cell(forIndex: 10_000) == (row: 9, column: 39))
        #expect(grid.cell(forIndex: -1) == (row: 0, column: 0))
    }

    @Test func caretSpanCoversASingleCell() {
        #expect(
            grid.span(for: NSRange(location: 127, length: 0))
                == (row: 3, column: 7, widthCells: 1)
        )
    }

    @Test func spanStopsAtTheEndOfItsStartingRow() {
        // A terminal row has no soft-wrap identity here, so a bounds query never
        // reports a rect straddling two rows.
        #expect(
            grid.span(for: NSRange(location: 38, length: 10))
                == (row: 0, column: 38, widthCells: 2)
        )
    }

    @Test func lineRangesCoverWholeRowsAndRejectOutOfBounds() {
        #expect(grid.range(forLine: 0) == NSRange(location: 0, length: 40))
        #expect(grid.range(forLine: 9) == NSRange(location: 360, length: 40))
        #expect(grid.range(forLine: 10) == NSRange(location: 0, length: 0))
        #expect(grid.range(forLine: -1) == NSRange(location: 0, length: 0))
    }
}

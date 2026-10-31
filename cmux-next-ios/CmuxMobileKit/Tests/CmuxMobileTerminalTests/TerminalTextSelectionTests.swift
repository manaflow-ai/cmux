import Testing
@testable import CmuxMobileTerminal

/// G-14 (T-SEL-01/02): text selection over terminal text, scrollback included.
/// Rows are absolute (0 = the oldest scrollback row), columns are cells.
@Suite struct TerminalTextSelectionTests {
    typealias P = TerminalCellPoint

    @Test func aLongPressSelectsTheWordUnderTheFinger() {
        let line = "$ git push origin main"
        let s = TerminalTextSelection.word(at: P(row: 40, column: 7), line: line, columns: 53)
        #expect(s.start == P(row: 40, column: 6))
        #expect(s.end == P(row: 40, column: 9))
        // A path is one word, like a URL in Terminal.
        let path = TerminalTextSelection.word(at: P(row: 3, column: 10), line: "cd ~/cmux-next/cmux-next-ios.rs ok", columns: 53)
        #expect(path.start.column == 3)
        #expect(path.end.column == 30)
        // On a blank the press selects that one cell.
        let blank = TerminalTextSelection.word(at: P(row: 1, column: 5), line: "ab    cd", columns: 53)
        #expect(blank.start == blank.end)
        // Past the line's end: the cell, clamped to the grid.
        #expect(TerminalTextSelection.word(at: P(row: 1, column: 80), line: "ab", columns: 53).end.column == 52)
    }

    @Test func draggingAHandlePastTheOtherSwapsThem() {
        var s = TerminalTextSelection(anchor: P(row: 10, column: 4), head: P(row: 10, column: 8))
        s.move(.start, to: P(row: 12, column: 2))
        #expect(s.start == P(row: 10, column: 8))
        #expect(s.end == P(row: 12, column: 2))
        s.move(.end, to: P(row: 9, column: 0))
        #expect(s.start == P(row: 9, column: 0))
        #expect(s.end == P(row: 10, column: 8))
    }

    @Test func rowSpansCoverWholeMiddleRows() {
        let s = TerminalTextSelection(anchor: P(row: 5, column: 50), head: P(row: 7, column: 3))
        let spans = s.rowSpans(columns: 53)
        #expect(spans.map(\.row) == [5, 6, 7])
        #expect(spans[0].columns == 50..<53)
        #expect(spans[1].columns == 0..<53)
        #expect(spans[2].columns == 0..<4)
    }

    @Test func selectAllTakesTheWholeDocument() {
        let s = TerminalTextSelection.all(originRow: 12, endRow: 900, columns: 53)
        #expect(s.start == P(row: 12, column: 0))
        #expect(s.end == P(row: 899, column: 52))
    }

    @Test func copiedTextDropsTrailingBlanksOfEachRow() {
        #expect(TerminalTextSelection.cleaned("abc   \nde  \n\n") == "abc\nde")
    }
}

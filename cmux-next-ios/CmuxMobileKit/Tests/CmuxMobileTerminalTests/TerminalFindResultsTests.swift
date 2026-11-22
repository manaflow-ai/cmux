import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Find in the terminal (the Mac's Find…): case-insensitive matches over the scrollback,
/// across soft wraps, the newest first, Next and Previous wrapping.
@Suite struct TerminalFindResultsTests {
    @Test func matchesAreFoundCaseInsensitivelyAndTheNewestIsSelected() {
        let rows = ["$ make", "error: one", "ok", "ERROR: two", "Error three error"]
        let find = TerminalFindResults(rows: rows, wraps: Array(repeating: false, count: rows.count), firstRow: 0, columns: 80, query: "error")
        #expect(find.matches.map(\.row) == [1, 3, 4, 4])
        #expect(find.matches[3].segments == [TerminalLink.Segment(row: 4, start: 12, end: 16)])
        #expect(find.selected == 3)
        #expect(find.position == 4)
    }

    @Test func nextAndPreviousWrap() {
        let rows = ["a x", "b x", "c x"]
        var find = TerminalFindResults(rows: rows, wraps: [false, false, false], firstRow: 10, columns: 80, query: "x")
        #expect(find.selectedMatch?.row == 12)
        find.step(forward: false)
        #expect(find.selectedMatch?.row == 11)
        find.step(forward: true)
        find.step(forward: true)
        #expect(find.selectedMatch?.row == 10)
        find.step(forward: false)
        #expect(find.selectedMatch?.row == 12)
    }

    @Test func aMatchAcrossASoftWrapCoversBothRows() {
        // 10 columns: "hello world" soft wrapped after "hello worl".
        let rows = ["hello worl", "d again"]
        let find = TerminalFindResults(rows: rows, wraps: [true, false], firstRow: 0, columns: 10, query: "world")
        #expect(find.matches.count == 1)
        #expect(find.matches[0].segments == [TerminalLink.Segment(row: 0, start: 6, end: 9), TerminalLink.Segment(row: 1, start: 0, end: 0)])
    }

    @Test func noQueryOrNoMatchIsEmptyAndPrunedRowsShiftTheMatches() {
        #expect(TerminalFindResults(rows: ["abc"], wraps: [false], firstRow: 0, columns: 80, query: "").matches.isEmpty)
        let none = TerminalFindResults(rows: ["abc"], wraps: [false], firstRow: 0, columns: 80, query: "zz")
        #expect(none.matches.isEmpty && none.selected == nil && none.position == nil)
        var find = TerminalFindResults(rows: ["x", "y", "x", "x"], wraps: [false, false, false, false], firstRow: 0, columns: 80, query: "x")
        find.step(forward: false)
        #expect(find.selectedMatch?.row == 2)
        // Ghostty dropped its 1 oldest row: the first match left the history.
        find.shiftRows(by: -1)
        #expect(find.matches.map(\.row) == [1, 2])
        #expect(find.selectedMatch?.row == 1)
        #expect(find.matches(in: 2..<5).map { $0.index } == [1])
    }

    @Test func pastTheLimitTheNewestMatchesAreKept() {
        let rows = Array(repeating: "x", count: TerminalFindResults.limit + 50)
        let find = TerminalFindResults(rows: rows, wraps: Array(repeating: false, count: rows.count), firstRow: 0, columns: 80, query: "x")
        #expect(find.matches.count == TerminalFindResults.limit)
        #expect(find.matches.first?.row == 50)
        #expect(find.selectedMatch?.row == rows.count - 1)
    }

    @Test func aWideCharacterBeforeAMatchShiftsItsCellsAndOddQueriesEnd() {
        let find = TerminalFindResults(rows: ["日本 tag"], wraps: [false], firstRow: 0, columns: 80, query: "TAG")
        #expect(find.matches.map(\.segments) == [[TerminalLink.Segment(row: 0, start: 5, end: 7)]])
        // A query of an invisible character finds nothing and ends.
        #expect(TerminalFindResults(rows: ["abc"], wraps: [false], firstRow: 0, columns: 80, query: "\u{200B}").matches.isEmpty)
    }
}

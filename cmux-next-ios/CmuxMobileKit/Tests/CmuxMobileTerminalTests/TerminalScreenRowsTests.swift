import Testing
@testable import CmuxMobileTerminal

/// G-14: a selection anywhere in the scrollback copies exact text, joined
/// only at soft wraps, from Ghostty's two unclamped whole-screen reads.
@Suite struct TerminalScreenRowsTests {
    typealias P = TerminalCellPoint

    /// A 10-column screen: row 2 soft-wraps into row 3 ("0123456789abc").
    let rectangle = "first\n\n0123456789\nabc\nlast row"
    let logical = "first\n\n0123456789abc\nlast row"

    @Test func rowsKeepTheScrollbarsNumberingAndTheirWraps() {
        let screen = TerminalScreenRows(rectangle: rectangle, logical: logical, columns: 10)
        #expect(screen.count == 5)
        #expect(screen.rows[2] == "0123456789")
        #expect(screen.wraps == [false, false, true, false, false])
    }

    @Test func aCopyAcrossASoftWrapIsOneLineAndAcrossHardBreaksKeepsThem() {
        let screen = TerminalScreenRows(rectangle: rectangle, logical: logical, columns: 10)
        #expect(screen.text(from: P(row: 2, column: 8), to: P(row: 3, column: 1)) == "89ab")
        #expect(screen.text(from: P(row: 0, column: 0), to: P(row: 4, column: 3)) == "first\n\n0123456789abc\nlast")
        #expect(screen.text(from: P(row: 9, column: 0), to: P(row: 9, column: 3)) == nil)
    }

    @Test func aWrappedRowThatEndedInBlanksStillJoins() {
        // "ab        cd" wrapped at 10 columns: the rectangle trims row 0's blanks.
        let screen = TerminalScreenRows(rectangle: "ab\ncd", logical: "ab        cd", columns: 10)
        #expect(screen.wraps == [true, false])
        #expect(screen.text(from: P(row: 0, column: 0), to: P(row: 1, column: 1)) == "ab        cd")
    }

    @Test func rowsFarDownTheScrollbackAreAddressable() {
        // 3000 rows, none wrapped: row 2500 reads row 2500 (round 8 read row 150 for it).
        let lines = (0..<3000).map { String(format: "#%07d", $0) }.joined(separator: "\n")
        let screen = TerminalScreenRows(rectangle: lines, logical: lines, columns: 53)
        #expect(screen.text(from: P(row: 2500, column: 0), to: P(row: 2501, column: 52)) == "#0002500\n#0002501")
    }
}

extension TerminalScreenRowsTests {
    @Test func aOneMegabyteLineAlignsInLinearTime() {
        // line1m: one line of 1 MiB wrapped at 53 columns (19,785 rows).
        let line = String(repeating: "abcdefghij", count: 104_858)
        let bytes = Array(line.utf8)
        let rows = stride(from: 0, to: bytes.count, by: 53).map { String(decoding: bytes[$0..<min($0 + 53, bytes.count)], as: UTF8.self) }
        let screen = TerminalScreenRows(rectangle: rows.joined(separator: "\n") + "\n$ ", logical: line + "\n$ ", columns: 53)
        #expect(screen.wraps.filter { $0 }.count == rows.count - 1)
        #expect(screen.text(from: TerminalCellPoint(row: 10_000, column: 0), to: TerminalCellPoint(row: 10_000, column: 4)) == "abcde")
    }
}

import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// Verifier defect V2-3 (VERIFY-round2.md, T-LIFE-09): a link drop while
/// reading brought the page back at the live bottom. The reattach's replay
/// rebuilds the scrollback, so the reader's rows are found again by their
/// text, nearest to where they were counted from the end.
@Suite struct TerminalReadingMarkTests {
    private func history(_ count: Int, prefix: String = "line") -> [String] {
        (0..<count).map { "\(prefix) \($0)" }
    }

    private func mark(in rows: [String], at row: Int) -> TerminalReadingMark? {
        TerminalReadingMark(anchor: .init(row: row, delta: 5), totalRows: rows.count) { rows.indices.contains($0) ? rows[$0] : nil }
    }

    private func locate(_ mark: TerminalReadingMark, in rows: [String]) -> TerminalScrollModel.Anchor? {
        mark.locate(totalRows: rows.count) { rows.indices.contains($0) ? rows[$0] : nil }
    }

    /// VERIFY-round6 V2-3 residual (G-D, fl-gd-2 trip 9): `reading mark row
    /// 15037 of 17633`, `restored row 15037 -> 14266 of 16862`, 116 rows low.
    /// The replay's rows far from its end cannot be read (Ghostty addresses
    /// only the viewport, the active area and the first rows; round 8), so the
    /// search fell back to the same distance from the end, and output during
    /// the drop (116 rows) moved the end. The rows that were at the end before
    /// the drop are still readable near the new end: they give the shift.
    @Test func theOldEndRowsGiveTheShiftWhenTheAnchorCannotBeRead() throws {
        let before = (0..<17633).map { "GEN-\($0 + 1000)" }
        let m = try #require(mark(in: before, at: 15037))
        // The Mac's history starts 771 rows later; 116 rows arrived during the drop.
        let after = Array(before[771...]) + (0..<116).map { "GEN-\(17633 + 1000 + $0)" }
        #expect(after.count == 16978)
        let readable = (after.count - 151)..<after.count
        let found = m.locate(totalRows: after.count) { readable.contains($0) ? after[$0] : nil }
        #expect(found?.row == 15037 - 771)
    }

    /// VERIFY-round8 T-LIFE-09/15 (disruptive): after a drop while output kept
    /// arriving, the page came back 225-388 rows lower, 3 of 3 runs, a single
    /// drop with no prune included. The anchor's rows and the old end were
    /// past the readable rows near the new end, so the search fell back to the
    /// same distance from the end: the rows that arrived during the drop pushed
    /// the reader down by their count. Rows that arrive only append; with
    /// nothing found by text, the reader's row stays where it was.
    @Test func rowsThatArriveDuringTheDropNeverPushTheReaderDown() throws {
        let before = (0..<1000).map { "GEN-\($0)" }
        let m = try #require(mark(in: before, at: 600))
        let after = before + (1000..<1300).map { "GEN-\($0)" }
        let readable = (after.count - 151)..<after.count
        let found = m.locate(totalRows: after.count) { readable.contains($0) ? after[$0] : nil }
        #expect(found?.row == 600)
    }

    /// The same drop with repeated rows (a GEN loop prints the same lines): the
    /// match nearest the reader's own row wins, not the one nearest the
    /// distance from the end.
    @Test func repeatedRowsAfterOutputDuringTheDropKeepTheReadersRow() throws {
        let block = (0..<50).map { "loop \($0)" }
        let before = Array((0..<20).map { _ in block }.joined())
        let m = try #require(mark(in: before, at: 610))
        let after = before + Array((0..<6).map { _ in block }.joined())
        #expect(locate(m, in: after)?.row == 610)
    }

    @Test func theSameHistoryKeepsTheSameRow() throws {
        let rows = history(500)
        let m = try #require(mark(in: rows, at: 200))
        #expect(locate(m, in: rows) == .init(row: 200, delta: 5))
    }

    @Test func outputDuringTheDropKeepsTheReadersRows() throws {
        let before = history(500)
        let m = try #require(mark(in: before, at: 200))
        // 40 new rows arrived while the link was down.
        let after = history(540)
        #expect(locate(m, in: after) == .init(row: 200, delta: 5))
    }

    @Test func aShorterReplayFindsTheRowsByText() throws {
        // The Mac's history starts later than the phone's did (V2-5): the
        // same rows sit 300 rows higher in the replay.
        let before = history(500)
        let m = try #require(mark(in: before, at: 400))
        let after = Array(before.dropFirst(300))
        #expect(locate(m, in: after) == .init(row: 100, delta: 5))
    }

    @Test func repeatedLinesPickTheNearestMatch() throws {
        var rows = Array(repeating: "same", count: 600)
        for i in stride(from: 0, to: 600, by: 7) { rows[i] = "mark \(i % 3)" }
        let m = try #require(mark(in: rows, at: 301))
        #expect(locate(m, in: rows)?.row == 301)
    }

    @Test func goneRowsFallBackToTheDistanceFromTheEnd() throws {
        let m = try #require(mark(in: history(500), at: 450))
        let after = history(500, prefix: "other")
        #expect(locate(m, in: after) == .init(row: 450, delta: 5))
    }

    @Test func blankRowsAloneAreNoMark() {
        let rows = Array(repeating: "", count: 100)
        #expect(mark(in: rows, at: 50) == nil)
    }

    /// Verifier V2-3 (round 3): once the replay's row count differed from the
    /// phone's, 5 of 5 read-drops lost the place: one changed row among the six
    /// read (a line the replay serializes differently, a redrawn status row)
    /// and the exact match failed, falling back to the distance from the end.
    /// The rows read and their neighbours vote; a few changed rows do not lose
    /// the place.
    @Test func aChangedRowAmongTheReadRowsStillFindsThem() throws {
        let before = history(1118)
        let m = try #require(mark(in: before, at: 835))
        // The Mac's history starts 120 rows later and grew 220 rows; one row
        // just below the anchor reads differently in the replay.
        var after = Array(before.dropFirst(120)) + history(220, prefix: "new")
        after[835 - 120 + 2] = "line 837 (redrawn)"
        #expect(locate(m, in: after)?.row == 835 - 120)
    }

    /// Rows read that are blank at the anchor are found by their neighbours.
    @Test func blankRowsUnderTheAnchorAreFoundByTheirNeighbours() throws {
        var before = history(600)
        for row in 300..<310 { before[row] = "" }
        let m = try #require(mark(in: before, at: 300))
        let after = Array(before.dropFirst(50)) + history(80, prefix: "new")
        #expect(locate(m, in: after)?.row == 250)
    }
}

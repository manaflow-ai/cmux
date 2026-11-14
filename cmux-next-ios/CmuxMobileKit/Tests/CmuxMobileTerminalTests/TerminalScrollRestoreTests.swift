import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-14: "Every time I navigate away from it now ... I have to
/// scroll all the way back to where I was." A tab that left the warm set comes
/// back on a new host whose replay starts with the Mac's latest screen
/// (`attach-replay-history-rows-v1`); a link drop's reattach can replay fewer
/// rows than the reader was above the end. The reader's rows are asked for
/// (bounded) and found again from the end of the new replay.
@Suite struct TerminalScrollRestoreTests {
    /// The Mac's history: `count` rows, each naming its row in the Mac's own numbering.
    private func history(_ count: Int) -> [String] {
        (0..<count).map { "line \($0)" }
    }

    private func mark(in rows: [String], at row: Int) throws -> TerminalReadingMark {
        try #require(TerminalReadingMark(anchor: .init(row: row, delta: 3), totalRows: rows.count) {
            rows.indices.contains($0) ? rows[$0] : nil
        })
    }

    private func replay(_ restore: inout TerminalScrollRestore, _ rows: [String], loadOlder: () -> Bool = { false })
        -> TerminalScrollModel.Anchor? {
        restore.replayed(totalRows: rows.count, rowText: { rows.indices.contains($0) ? rows[$0] : nil }, loadOlder: loadOlder)
    }

    /// A cooled tab read row 2,500 of the 3,000 its old host held. The new
    /// host's replay holds the Mac's last 2,060 rows (the newest screen and one
    /// chunk of history): the same rows are 500 rows above its end.
    @Test func aNewHostFindsTheRowsAtTheirDistanceFromTheEnd() throws {
        let mac = history(3_000)
        let place = TerminalScrollPlace(mark: try mark(in: mac, at: 2_500))
        #expect(place.rowsFromEnd == 500)
        var restore = TerminalScrollRestore(place: place)
        let replayed = Array(mac[940...])
        let anchor = replay(&restore, replayed)
        #expect(anchor == .init(row: 2_500 - 940, delta: 3))
        #expect(restore.olderLoads == 0)
    }

    /// The same with a program that prints the same block over and over: the
    /// copy at the reader's distance from the end wins, not the one nearest
    /// the row number the old host gave it.
    @Test func repeatedRowsPickTheCopyAtTheReadersDistanceFromTheEnd() throws {
        let block = (0..<50).map { "loop \($0)" }
        let mac = (0..<80).flatMap { _ in block }
        #expect(mac.count == 4_000)
        let place = TerminalScrollPlace(mark: try mark(in: mac, at: 3_210))
        var restore = TerminalScrollRestore(place: place)
        // The new host holds the last 2,000 rows: the reader's row is 1,210 of them.
        let anchor = replay(&restore, Array(mac[2_000...]))
        #expect(anchor?.row == 1_210)
    }

    /// The reader was 2,500 rows above the end and the replay is the screen
    /// alone: older rows are asked for until the replay holds them.
    @Test func olderRowsAreAskedForUntilTheReplayHoldsTheReader() throws {
        let mac = history(6_000)
        var restore = TerminalScrollRestore(place: TerminalScrollPlace(mark: try mark(in: mac, at: 3_500)))
        var asked = 0
        let load = { asked += 1; return true }
        #expect(replay(&restore, Array(mac[5_950...]), loadOlder: load) == nil)
        #expect(asked == 1)
        #expect(replay(&restore, Array(mac[3_950...]), loadOlder: load) == nil)
        #expect(asked == 2)
        let anchor = replay(&restore, Array(mac[1_950...]), loadOlder: load)
        #expect(asked == 2)
        #expect(anchor == .init(row: 3_500 - 1_950, delta: 3))
    }

    /// A link drop's reattach replays the screen alone (the reader never
    /// fetched older rows; the rows they read came in as output). The reader
    /// is above it: older rows come, then the place counts from the new end.
    @Test func aLinkDropShortOfTheReaderFetchesOlderRows() throws {
        let mac = history(1_000)
        var restore = TerminalScrollRestore(mark: try mark(in: Array(mac[200...]), at: 300), fromEnd: false)
        var asked = 0
        #expect(replay(&restore, Array(mac[950...]), loadOlder: { asked += 1; return true }) == nil)
        #expect(asked == 1)
        #expect(restore.fromEnd)
        // The fetch brought the whole history: the reader's row 300 was the Mac's row 500.
        #expect(replay(&restore, mac)?.row == 500)
    }

    /// Fetches are bounded: past ``TerminalScrollRestore/maxOlderLoads`` the
    /// page shows the oldest row it holds.
    @Test func olderRowFetchesAreBounded() throws {
        let mac = history(100_000)
        var restore = TerminalScrollRestore(place: TerminalScrollPlace(mark: try mark(in: mac, at: 10)))
        var asked = 0
        let screen = Array(mac[99_950...])
        for _ in 0..<TerminalScrollRestore.maxOlderLoads {
            #expect(replay(&restore, screen, loadOlder: { asked += 1; return true }) == nil)
        }
        #expect(replay(&restore, screen, loadOlder: { asked += 1; return true }) == .init(row: 0, delta: 0))
        #expect(asked == TerminalScrollRestore.maxOlderLoads)
    }

    /// The Mac has no older rows (or the session cannot fetch them): the
    /// oldest row the page holds, not the live bottom.
    @Test func noOlderRowsShowsTheOldestRow() throws {
        let mac = history(3_000)
        var restore = TerminalScrollRestore(place: TerminalScrollPlace(mark: try mark(in: mac, at: 100)))
        #expect(replay(&restore, Array(mac[2_000...]), loadOlder: { false }) == .init(row: 0, delta: 0))
        #expect(restore.olderLoads == 0)
    }

    /// A link drop whose replay holds the reader keeps today's search: the
    /// reader's own row first (rows that arrive during a drop only append).
    @Test func aLinkDropThatHoldsTheReaderKeepsItsOwnRow() throws {
        let before = history(1_000)
        let m = try mark(in: before, at: 600)
        var restore = TerminalScrollRestore(mark: m, fromEnd: false)
        let after = before + (1_000..<1_300).map { "line \($0)" }
        #expect(replay(&restore, after, loadOlder: { Issue.record("no fetch: the replay holds the reader"); return true })?.row == 600)
    }
}

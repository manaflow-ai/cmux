import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The top strip's target (Leo, 2026-11-23: "click (tap) the top bit of the
/// terminal in phone to jump to that last sent bit"): the last line sent,
/// found again by its text, else by the row it went at.
@Suite struct TerminalLastSentTests {
    @Test func previewIsTheFirstLineWithTextCollapsed() throws {
        let sent = try #require(TerminalLastSent(text: "\n   cargo   build\n--release", row: 4))
        #expect(sent.preview == "cargo build")
        #expect(sent.row == 4)
        #expect(TerminalLastSent(text: "", row: 1) == nil, "a bare Return keeps the last one")
        #expect(TerminalLastSent(text: " \n\t", row: 1) == nil)
    }

    @Test func textFindsTheEchoWhereverTheProgramDrewIt() throws {
        // An agent CLI: the input box was at row 9 when it went, the
        // transcript echoes it at row 3.
        let rows = ["", "header", "", "> explain   the  build", "thinking…", "answer", "", "", "", "> "]
        let sent = try #require(TerminalLastSent(text: "explain the build", row: 9))
        #expect(sent.locate(in: rows) == 3)
    }

    @Test func theSamePromptTwiceGoesToTheRecordedOne() throws {
        let rows = ["% ls", "a b", "% ls", "a b", "% ls", "a b", "%"]
        let older = try #require(TerminalLastSent(text: "ls", row: 2))
        #expect(older.locate(in: rows) == 2)
        let newest = try #require(TerminalLastSent(text: "ls", row: 4))
        #expect(newest.locate(in: rows) == 4)
        let unknown = try #require(TerminalLastSent(text: "ls", row: nil))
        #expect(unknown.locate(in: rows) == 4, "no row: the newest echo")
    }

    @Test func rowIsTheFallbackWhenTheTextIsGone() throws {
        let sent = try #require(TerminalLastSent(text: "secret typed with echo off", row: 2))
        #expect(sent.locate(in: ["a", "b", "c"]) == 2)
        #expect(sent.locate(in: ["a"]) == nil, "the row is past the rows held")
    }

    @Test func pruneMovesTheRowAndDropsItWhenPrunedAway() throws {
        var sent = try #require(TerminalLastSent(text: "make", row: 10))
        sent.shiftRows(by: -4)
        #expect(sent.row == 6)
        sent.shiftRows(by: -7)
        #expect(sent.row == nil)
        #expect(sent.locate(in: ["x", "% make", "y"]) == 1, "the text still finds it")
    }

    @Test func longPromptsMatchOnTheirStartAcrossAWrap() throws {
        let long = "please refactor the terminal scroll model so the strip lands on the sent row"
        let sent = try #require(TerminalLastSent(text: long, row: nil))
        // A 40-column phone grid wrapped it after the marker.
        let rows = ["> please refactor the terminal scroll mo", "del so the strip lands on the sent row", "ok"]
        #expect(sent.locate(in: rows) == 0)
    }

    @Test func stripShowsOnlyWhileTheRowIsOffScreenOnTheShell() {
        #expect(TerminalLastSent.stripShows(row: 3, visibleRows: 10..<40, isTUI: false))
        #expect(TerminalLastSent.stripShows(row: 50, visibleRows: 10..<40, isTUI: false), "scrolled up past it: back down to it")
        #expect(!TerminalLastSent.stripShows(row: 12, visibleRows: 10..<40, isTUI: false))
        #expect(!TerminalLastSent.stripShows(row: 3, visibleRows: 10..<40, isTUI: true), "a full-screen app owns its screen")
        #expect(!TerminalLastSent.stripShows(row: nil, visibleRows: 10..<40, isTUI: false))
    }
}

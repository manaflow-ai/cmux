import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-24: "sometimes the highlights in terminal just float and dont move when i
/// scroll?" A full-screen app scrolled its screen: a highlight held as viewport rows finds its
/// text again, nearest first, or knows it left.
@Suite struct TerminalRowFollowTests {
    @Test func rowsStillInPlaceDoNotMove() {
        let screen = ["header", "one", "two", "three", "footer"]
        #expect(TerminalRowFollow.delta(selected: ["two"], firstRow: 2, screen: screen) == 0)
    }

    @Test func rowsTheAppScrolledUpMoveUpWithIt() {
        // Before: ["header", "one", "two", "three", "four", "footer"].
        let after = ["header", "three", "four", "five", "six", "footer"]
        #expect(TerminalRowFollow.delta(selected: ["three", "four"], firstRow: 3, screen: after) == -2)
    }

    @Test func rowsTheAppScrolledDownMoveDown() {
        let after = ["header", "zero", "one", "two", "footer"]
        #expect(TerminalRowFollow.delta(selected: ["one"], firstRow: 1, screen: after) == 1)
    }

    @Test func textThatLeftTheScreenIsGone() {
        let after = ["header", "five", "six", "seven", "footer"]
        #expect(TerminalRowFollow.delta(selected: ["two"], firstRow: 2, screen: after) == nil)
        // Half of it left: not on the screen whole.
        #expect(TerminalRowFollow.delta(selected: ["four", "five"], firstRow: 1, screen: ["five", "six"]) == nil)
    }

    @Test func theNearestCopyWins() {
        let after = ["x", "same", "x", "x", "same", "x"]
        #expect(TerminalRowFollow.delta(selected: ["same"], firstRow: 3, screen: after) == 1)
        #expect(TerminalRowFollow.delta(selected: ["same"], firstRow: 2, screen: after) == -1)
    }

    @Test func trailingBlanksAndBlankRowsDoNotCount() {
        let after = ["a", "b   ", "", "c", "d"]
        #expect(TerminalRowFollow.delta(selected: ["b", "", "c"], firstRow: 0, screen: after) == 1)
        #expect(TerminalRowFollow.delta(selected: ["", "  "], firstRow: 1, screen: ["q", "r"]) == 0)
    }

    @Test func aRowRewrittenInPlaceKeepsItsHighlight() {
        // htop's CPU row, a spinner, a streamed Claude line: the selected row changed, the rows
        // around it did not move.
        let before = ["header", "cpu 12%", "footer"]
        let after = ["header", "cpu 47%", "footer"]
        #expect(TerminalRowFollow.follow(selected: [before[1]], above: before[0], below: before[2],
                                         firstRow: 1, screen: after) == .rewritten)
        // Copy Mode's cursor cell at the screen's top: no row above it.
        #expect(TerminalRowFollow.follow(selected: ["a"], above: nil, below: "b", firstRow: 0,
                                         screen: ["z", "b"]) == .rewritten)
    }

    @Test func aRowThatScrolledOffIsGoneNotRewritten() {
        let after = ["header", "five", "six", "footer"]
        #expect(TerminalRowFollow.follow(selected: ["two"], above: "one", below: "three", firstRow: 2,
                                         screen: after) == .gone)
        #expect(TerminalRowFollow.follow(selected: ["two"], above: "one", below: "three", firstRow: 2,
                                         screen: ["x", "one", "two", "three"]) == .moved(0))
        #expect(TerminalRowFollow.follow(selected: ["two"], above: "one", below: "three", firstRow: 2,
                                         screen: ["one", "two", "three", "x"]) == .moved(-1))
        // A screen cleared before it is drawn again: the rows went blank.
        #expect(TerminalRowFollow.follow(selected: ["two"], above: "one", below: "three", firstRow: 1,
                                         screen: ["", "", "", ""]) == .gone)
        // Nothing around it to vouch for a rewrite.
        #expect(TerminalRowFollow.follow(selected: ["two"], above: "", below: nil, firstRow: 1,
                                         screen: ["", "seven"]) == .gone)
    }

    @Test func aRepeatedRowFollowsTheCopyItsNeighboursVouchFor() {
        // A one-row selection on a "---" rule: the screen scrolled up by three, and another
        // rule came to where it was (the nearest copy, the wrong one).
        let before = ["x", "a", "---", "b", "y", "---", "z"]
        let after = ["b", "y", "---", "z", "q", "---", "w"]
        #expect(TerminalRowFollow.delta(selected: [before[5]], firstRow: 5, screen: after) == 0)
        #expect(TerminalRowFollow.follow(selected: [before[5]], above: before[4], below: before[6],
                                         firstRow: 5, screen: after) == .moved(-3))
        // Its neighbours are gone and the copies look alike: gone, not a guess.
        #expect(TerminalRowFollow.follow(selected: ["│"], above: "x", below: "y", firstRow: 1,
                                         screen: ["│", "│", "│"]) == .gone)
        // Nothing around it to tell copies apart, and one in place: it stays.
        #expect(TerminalRowFollow.follow(selected: ["│"], above: "", below: nil, firstRow: 1,
                                         screen: ["│", "│", "│"]) == .moved(0))
        // Copies whose neighbours do not tell them apart, none in place: gone.
        #expect(TerminalRowFollow.follow(selected: ["│"], above: "x", below: "x", firstRow: 0,
                                         screen: ["x", "│", "x", "│", "x"]) == .gone)
    }
}

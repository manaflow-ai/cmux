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
}

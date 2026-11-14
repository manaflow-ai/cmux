import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// design/terminal R1-1: one PTY resize after the keyboard settles, for TUIs.
@Suite struct TerminalTUISizingTests {
    let resting: CGFloat = 676, top: CGFloat = 62, cell: CGFloat = 16.4

    private func rows(_ sizing: TerminalTUISizing) -> Int {
        sizing.rows(restingStackTop: resting, chromeTop: top, cellHeight: cell)
    }

    @Test func keyboardDownGivesTheRestingRows() {
        #expect(rows(TerminalTUISizing()) == 37)
    }

    @Test func aTUIShrinksOnceTheKeyboardSettlesAndGrowsBack() {
        var sizing = TerminalTUISizing()
        sizing.tuiStarted()
        // Mid-animation nothing settled: the rows do not follow the frames.
        #expect(rows(sizing) == 37)
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, isTUI: true)
        // top's header fits above the composer: (400 - 62) / 16.4 = 20 rows.
        #expect(rows(sizing) == 20)
        sizing.keyboardSettled(stackTop: resting, restingStackTop: resting, isTUI: true)
        #expect(rows(sizing) == 37)
    }

    @Test func aShellKeepsItsRowsWithTheKeyboardUp() {
        var sizing = TerminalTUISizing()
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, isTUI: false)
        #expect(rows(sizing) == 37)
        // A TUI started with the keyboard up gets the rows above the composer.
        sizing.tuiStarted()
        #expect(rows(sizing) == 20)
    }

    /// R2-1: `top` with the keyboard up, then `q`: the shell gets its
    /// keyboard-down rows back at once, not the TUI's 20.
    @Test func quittingATUIWithTheKeyboardUpRestoresTheShellRows() {
        var sizing = TerminalTUISizing()
        sizing.tuiStarted()
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, isTUI: true)
        #expect(rows(sizing) == 20)
        sizing.tuiEnded()
        #expect(rows(sizing) == 37)
        // Another TUI with the keyboard still up fits above it again.
        sizing.tuiStarted()
        #expect(rows(sizing) == 20)
    }

    /// The settled stack top is a position on the page. A dock change after it
    /// (the composer or key row coming in) moves the resting top above it, and
    /// a TUI started then claimed rows below the composer: vim opened with the
    /// keyboard down and its first rows clipped under the toolbar (kbtui demo,
    /// stack top 790 pt kept while resting was 708 pt: 45 rows in a 40-row area).
    @Test func aTUINeverGetsMoreRowsThanTheKeyboardDownLayout() {
        var sizing = TerminalTUISizing()
        // Settled while the dock sat lower (no composer yet): not "up" then.
        sizing.keyboardSettled(stackTop: 790, restingStackTop: 800, isTUI: false)
        sizing.tuiStarted()
        // The dock grew: resting is now 676; 790 is below it.
        #expect(rows(sizing) == 37)
    }
}

/// User report 2026-10-14: no resize for a size that only lasts a layout pass.
@Suite struct TerminalResizeSettleTests {
    typealias Size = TerminalResizeSettle.Size

    @Test func theFirstSizeGoesAtOnce() {
        var settle = TerminalResizeSettle()
        #expect(settle.measured(Size(columns: 53, rows: 42)) == .sendNow(Size(columns: 53, rows: 42)))
    }

    @Test func aSizeThatRevertsWithinTheSettleIsNeverSent() {
        var settle = TerminalResizeSettle()
        _ = settle.measured(Size(columns: 53, rows: 42))
        // Mid-change: 39 rows for one pass, then 42 again (seen live).
        #expect(settle.measured(Size(columns: 53, rows: 39)) == .wait)
        #expect(settle.measured(Size(columns: 53, rows: 42)) == .nothing)
        #expect(settle.settled() == nil)
    }

    @Test func aSizeThatHoldsIsSentOnce() {
        var settle = TerminalResizeSettle()
        _ = settle.measured(Size(columns: 53, rows: 42))
        #expect(settle.measured(Size(columns: 53, rows: 24)) == .wait)
        #expect(settle.measured(Size(columns: 53, rows: 24)) == .nothing)
        #expect(settle.settled() == Size(columns: 53, rows: 24))
        #expect(settle.settled() == nil)
        #expect(settle.measured(Size(columns: 53, rows: 24)) == .nothing)
    }
}

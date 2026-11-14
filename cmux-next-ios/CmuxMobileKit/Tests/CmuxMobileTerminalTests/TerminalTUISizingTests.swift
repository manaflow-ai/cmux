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

    /// The keyboard's lift is kept as a distance. A dock or page change after
    /// it moves the resting top, and the rows follow: a kept page position
    /// gave a TUI rows under the composer (vim opened with its first rows
    /// clipped) or above it (a band of black).
    @Test func theRowsFollowTheRestingTopAfterTheKeyboardSettled() {
        var sizing = TerminalTUISizing()
        sizing.tuiStarted()
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, isTUI: true)
        #expect(rows(sizing) == 20)
        // The dock grew by 76 pt (the composer came in): the keyboard still
        // lifts the stack 276 pt, so (600 - 276 - 62) / 16.4 = 15 rows.
        #expect(sizing.rows(restingStackTop: 600, chromeTop: top, cellHeight: cell) == 15)
        // The page grew by 100 pt: (776 - 276 - 62) / 16.4 = 26 rows, not the old position's 20.
        #expect(sizing.rows(restingStackTop: 776, chromeTop: top, cellHeight: cell) == 26)
    }

    /// With the keyboard down a TUI gets exactly the resting rows, wherever
    /// the resting top moves.
    @Test func aTUIWithTheKeyboardDownGetsTheRestingRowsWhereverTheDockMoves() {
        var sizing = TerminalTUISizing()
        sizing.keyboardSettled(stackTop: resting, restingStackTop: resting, isTUI: false)
        sizing.tuiStarted()
        #expect(rows(sizing) == 37)
        // (810 - 62) / 16.4 = 45.6: the resting rows, not 37.
        #expect(sizing.rows(restingStackTop: 810, chromeTop: top, cellHeight: cell) == 45)
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

/// R1-1, M-BLACK: the old grid stays on the composer until the Mac's new one is in.
@Suite struct TerminalTUIGridHoldTests {
    @Test func theOldGridIsKeptUntilTheReplay() {
        var hold = TerminalTUIGridHold()
        #expect(hold.rows(page: 40) == 40)
        // The keyboard settled up: 25 rows asked, the Mac's 40 still drawn.
        hold.rowsChanged(from: 40, to: 25, shownRows: 40)
        #expect(hold.rows(page: 25) == 40)
        hold.release()
        #expect(hold.rows(page: 25) == 25)
        // And down again.
        hold.rowsChanged(from: 25, to: 40, shownRows: 25)
        #expect(hold.rows(page: 40) == 25)
    }

    @Test func turningBackBeforeTheAnswerShowsThePageRows() {
        var hold = TerminalTUIGridHold()
        hold.rowsChanged(from: 40, to: 25, shownRows: 40)
        // Another toggle settled before the Mac answered: still the 40 drawn.
        hold.rowsChanged(from: 25, to: 30, shownRows: 40)
        #expect(hold.rows(page: 30) == 40)
        hold.rowsChanged(from: 30, to: 40, shownRows: 40)
        #expect(hold.heldRows == nil)
        #expect(hold.rows(page: 40) == 40)
    }

    @Test func anAnswerAtEarlierRowsKeepsItsGridUntilThePagesOwn() {
        var hold = TerminalTUIGridHold()
        hold.rowsChanged(from: 40, to: 25, shownRows: 40)
        hold.rowsChanged(from: 25, to: 30, shownRows: 40)
        // The answer to 25 is drawn while 30 is still to be answered.
        hold.replayed(rows: 25, page: 30, claimPending: true)
        #expect(hold.rows(page: 30) == 25)
        hold.replayed(rows: 30, page: 30, claimPending: false)
        #expect(hold.rows(page: 30) == 30)
        // A replay that answers nothing pending (the Mac kept its grid) shows the page's rows.
        hold.rowsChanged(from: 30, to: 40, shownRows: 30)
        hold.replayed(rows: 30, page: 40, claimPending: false)
        #expect(hold.heldRows == nil)
    }

    @Test func aLocalSessionOrAnotherDevicesGridIsNotHeld() {
        var hold = TerminalTUIGridHold()
        hold.rowsChanged(from: 40, to: 25, shownRows: nil)
        #expect(hold.heldRows == nil)
        // The Mac's grid is another device's (50 rows): shown as it is.
        hold.rowsChanged(from: 40, to: 25, shownRows: 50)
        #expect(hold.heldRows == nil)
    }
}

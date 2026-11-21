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
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, keyboardShown: true, isTUI: true)
        // top's header fits above the composer: (400 - 62) / 16.4 = 20 rows.
        #expect(rows(sizing) == 20)
        sizing.keyboardSettled(stackTop: resting, restingStackTop: resting, keyboardShown: false, isTUI: true)
        #expect(rows(sizing) == 37)
    }

    @Test func aShellKeepsItsRowsWithTheKeyboardUp() {
        var sizing = TerminalTUISizing()
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, keyboardShown: true, isTUI: false)
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
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, keyboardShown: true, isTUI: true)
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
        sizing.keyboardSettled(stackTop: 400, restingStackTop: resting, keyboardShown: true, isTUI: true)
        #expect(rows(sizing) == 20)
        // The dock grew by 76 pt (the composer came in): the keyboard still
        // lifts the stack 276 pt, so (600 - 276 - 62) / 16.4 = 15 rows.
        #expect(sizing.rows(restingStackTop: 600, chromeTop: top, cellHeight: cell) == 15)
        // The page grew by 100 pt: (776 - 276 - 62) / 16.4 = 26 rows, not the old position's 20.
        #expect(sizing.rows(restingStackTop: 776, chromeTop: top, cellHeight: cell) == 26)
    }

    /// A settle with the keyboard down is never a lift, even when the stack
    /// sat above the resting top it was measured against (a tab's insets
    /// arrived after the page's first settle: 8 pt, a row of the app lost).
    @Test func aSettleWithTheKeyboardDownIsNeverALift() {
        var sizing = TerminalTUISizing()
        sizing.tuiStarted()
        sizing.keyboardSettled(stackTop: resting - 8, restingStackTop: resting, keyboardShown: false, isTUI: true)
        #expect(sizing.keyboardLift == nil)
        #expect(rows(sizing) == 37)
    }

    /// With the keyboard down a TUI gets exactly the resting rows, wherever
    /// the resting top moves.
    @Test func aTUIWithTheKeyboardDownGetsTheRestingRowsWhereverTheDockMoves() {
        var sizing = TerminalTUISizing()
        sizing.keyboardSettled(stackTop: resting, restingStackTop: resting, keyboardShown: false, isTUI: false)
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

/// R1-1, 2026-11-16: a keyboard toggle's target rows go to the Mac at once.
@Suite struct TerminalResizeSettleClaimTests {
    private func size(_ rows: Int) -> TerminalResizeSettle.Size { .init(columns: 53, rows: rows) }

    @Test func aTargetIsSentAtOnceAndTheSameOneNotAgain() {
        var settle = TerminalResizeSettle()
        #expect(settle.measured(size(40)) == .sendNow(size(40)))
        #expect(settle.claim(size(26)) == size(26))
        // Will-show claims the rows of its end frame: the same, nothing sent.
        #expect(settle.claim(size(26)) == nil)
        #expect(settle.applied == size(26))
    }

    @Test func aReversalSendsTheRevertAtOnce() {
        var settle = TerminalResizeSettle()
        _ = settle.measured(size(40))
        #expect(settle.claim(size(26)) == size(26))
        // The keyboard turned back before the Mac answered: the rows claimed
        // are never left at the abandoned target.
        #expect(settle.claim(size(40)) == size(40))
        #expect(settle.applied == size(40))
    }

    @Test func aClaimDropsAPendingMeasure() {
        var settle = TerminalResizeSettle()
        _ = settle.measured(size(40))
        #expect(settle.measured(size(39)) == .wait)
        #expect(settle.claim(size(26)) == size(26))
        #expect(settle.pending == nil)
        #expect(settle.settled() == nil)
    }
}

/// The area's bottom follows the settled keyboard for a TUI only.
@Suite struct TerminalTUISizingAreaBottomTests {
    @Test func theAreaBottomIsTheLiftedRestingTop() {
        var sizing = TerminalTUISizing()
        sizing.tuiStarted()
        #expect(sizing.areaBottom(restingStackTop: 676) == 676)
        sizing.keyboardSettled(stackTop: 400, restingStackTop: 676, keyboardShown: true, isTUI: true)
        #expect(sizing.areaBottom(restingStackTop: 676) == 400)
        sizing.tuiEnded()
        #expect(sizing.areaBottom(restingStackTop: 676) == 676)
    }
}

/// A held grid moves in one motion with the keyboard: carried up by a
/// rising composer, left at its rest inset by a falling one.
@Suite struct TerminalTUIHeldInsetTests {
    let cell: CGFloat = 16.4

    @Test func atRestTheHeldGridKeepsItsInset() {
        // 37 rows over a 614 pt room: 7.2 pt of sub-row rest.
        let held = TerminalTUIHeldInset(rest: 614 - 37 * cell, heldRows: 37, cellHeight: cell)
        #expect(abs(held.inset(room: 614) - (614 - 37 * cell)) < 0.001)
    }

    @Test func aRisingComposerCarriesTheGridWithItsLastRowOnTheComposer() {
        let held = TerminalTUIHeldInset(rest: 614 - 37 * cell, heldRows: 37, cellHeight: cell)
        // The keyboard lifts the stack 276 pt: the grid's bottom stays on it.
        let inset = held.inset(room: 338)
        #expect(abs(inset + 37 * cell - 338) < 0.001)
        #expect(inset < 0, "its top goes under the toolbar")
    }

    @Test func aFallingComposerLeavesTheGridAtItsRestInset() {
        // 20 rows held with the keyboard up (room 338), the keyboard hides.
        let rest = 338 - 20 * cell
        let held = TerminalTUIHeldInset(rest: rest, heldRows: 20, cellHeight: cell)
        #expect(held.inset(room: 614) == rest)
        #expect(held.inset(room: 500) == rest)
    }
}

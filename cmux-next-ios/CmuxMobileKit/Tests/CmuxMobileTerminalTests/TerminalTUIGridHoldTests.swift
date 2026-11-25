import Testing
@testable import CmuxMobileTerminal

/// M-BLACK: the old grid stays on the composer until the Mac's new one is in
/// (a chrome change; the soft keyboard never changes the rows).
@Suite struct TerminalTUIGridHoldTests {
    @Test func theOldGridIsKeptUntilTheReplay() {
        var hold = TerminalTUIGridHold()
        #expect(hold.rows(page: 40) == 40)
        // A chrome change: 25 rows asked, the Mac's 40 still drawn.
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
        // The rows changed again before the Mac answered: still the 40 drawn.
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

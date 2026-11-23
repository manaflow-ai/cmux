import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12: "the resizing is so wack when j tap the thijg";
/// 2026-11-15: "i meant previously there was the thing that stopped the
/// resizing when you closed the ios built in keyboard". The soft keyboard
/// insets the page; it never resizes the Mac's PTY.
@Suite struct TerminalGridSizingTests {
    typealias Size = TerminalResizeSettle.Size
    let resting: CGFloat = 676, top: CGFloat = 62, cell: CGFloat = 16.4

    private var sizing: TerminalGridSizing { TerminalGridSizing(cellHeight: cell) }

    /// One layout pass of the page: what the controller measures and feeds
    /// to the settle. The keyboard moves only `stackTop` (the stack rides it);
    /// the claimed rows read the resting top.
    private struct Page {
        var restingStackTop: CGFloat
        var chromeTop: CGFloat
        var columns: Int
        var stackTop: CGFloat
        func size(cell: CGFloat) -> Size {
            Size(columns: columns, rows: TerminalGridSizing(cellHeight: cell).rows(restingStackTop: restingStackTop, chromeTop: chromeTop))
        }
    }

    @Test func keyboardDownGivesTheRestingRows() {
        #expect(sizing.rows(restingStackTop: resting, chromeTop: top) == 37)
    }

    @Test func showingAndClosingTheKeyboardSendsNoResize() {
        var settle = TerminalResizeSettle()
        var page = Page(restingStackTop: resting, chromeTop: top, columns: 53, stackTop: resting)
        #expect(settle.measured(page.size(cell: cell)) == .sendNow(Size(columns: 53, rows: 37)))
        // Every layout pass of the keyboard's animation, up and back down,
        // tapped repeatedly (the key bar's keyboard button), TUI or shell.
        for _ in 0..<3 {
            for stackTop in Array(stride(from: resting, through: 340, by: -24)) + stride(from: 340, through: resting, by: 24) {
                page.stackTop = stackTop
                #expect(settle.measured(page.size(cell: cell)) == .nothing)
            }
        }
        #expect(settle.pending == nil)
        #expect(settle.settled() == nil)
    }

    /// The rows follow the page's own resting top: a dock or inset change
    /// (the composer coming in, a tab's insets arriving) changes them.
    @Test func theRowsFollowTheRestingTop() {
        #expect(sizing.rows(restingStackTop: 600, chromeTop: top) == 32)
        #expect(sizing.rows(restingStackTop: 810, chromeTop: top) == 45)
    }

    @Test func aRotationSendsExactlyOneDebouncedResize() {
        var settle = TerminalResizeSettle()
        let portrait = Page(restingStackTop: resting, chromeTop: top, columns: 53, stackTop: resting)
        _ = settle.measured(portrait.size(cell: cell))
        // The rotation's layout passes: transient sizes, then the landscape
        // page held. Each measured change restarts the wait; nothing is sent.
        let passes = [
            Page(restingStackTop: 500, chromeTop: 40, columns: 80, stackTop: 500),
            Page(restingStackTop: 330, chromeTop: 24, columns: 104, stackTop: 330),
            Page(restingStackTop: 330, chromeTop: 24, columns: 104, stackTop: 330),
        ]
        var actions: [TerminalResizeSettle.Action] = []
        for pass in passes { actions.append(settle.measured(pass.size(cell: cell))) }
        #expect(actions == [.wait, .wait, .nothing])
        // The settle elapsed: one resize, the landscape grid.
        #expect(settle.settled() == Size(columns: 104, rows: 18))
        #expect(settle.settled() == nil)
        // The keyboard in landscape: still nothing.
        #expect(settle.measured(Page(restingStackTop: 330, chromeTop: 24, columns: 104, stackTop: 180).size(cell: cell)) == .nothing)
    }

    @Test func noLiftWhileTheGridFits() {
        #expect(TerminalGridSizing(cellHeight: 16).keyboardLift(gridRows: 37, visibleHeight: 37 * 16, cursorRow: 0) == 0)
    }

    @Test func noLiftWhenTheCursorIsBelowTheClippedTop() {
        // Keyboard up: 20 rows visible of 37; the prompt near the bottom (Claude Code, a shell).
        let sizing = TerminalGridSizing(cellHeight: 16)
        #expect(sizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: 30) == 0)
        #expect(sizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: 17) == 0)
    }

    /// The top exception (Leo, 2026-11-15: "add the top exception? why roll
    /// the whole thing back"): 37 rows, 20 visible with the keyboard up.
    @Test func theHeaderStaysAboveABodyThatKeepsTheCursor() {
        typealias Placement = TerminalGridSizing.KeyboardPlacement
        let sizing = TerminalGridSizing(cellHeight: 16)
        func place(_ cursor: Int?) -> Placement { sizing.keyboardPlacement(gridRows: 37, visibleHeight: 20 * 16, cursorRow: cursor) }
        // Claude Code: the cursor in its input box on the last row. The
        // header's 3 rows pin above the bottom 17.
        #expect(place(36) == Placement(lift: 0, headerRows: 3))
        #expect(place(20) == Placement(lift: 0, headerRows: 3))
        // The cursor mid-grid: the body moves down until the cursor's row is
        // just under the header (row 10 at the body's top).
        #expect(place(10) == Placement(lift: 10 * 16, headerRows: 3))
        #expect(place(15) == Placement(lift: 5 * 16, headerRows: 3))
        // The cursor near the top: the grid's top as it is, no header.
        #expect(place(3) == Placement(lift: 17 * 16, headerRows: 0))
        #expect(place(0) == Placement(lift: 17 * 16, headerRows: 0))
        // Unknown cursor: header over the bottom rows.
        #expect(place(nil) == Placement(lift: 0, headerRows: 3))
        // The grid fits: nothing to pin.
        #expect(sizing.keyboardPlacement(gridRows: 20, visibleHeight: 20 * 16, cursorRow: 19) == Placement(lift: 0, headerRows: 0))
        // A short area keeps two thirds for the body: 6 visible rows, 2 header rows.
        #expect(sizing.keyboardPlacement(gridRows: 37, visibleHeight: 6 * 16, cursorRow: 36) == Placement(lift: 0, headerRows: 2))
    }

    @Test func aCursorUnderTheToolbarLiftsTheGridByWholeRows() {
        let sizing = TerminalGridSizing(cellHeight: 16)
        // vim on line 1 with the keyboard up: 17 rows clipped at the top.
        #expect(sizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: 0) == CGFloat(17 * 16))
        #expect(sizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: 10) == CGFloat(7 * 16))
        // Unknown cursor: the bottom rows stay above the keyboard.
        #expect(sizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: nil) == 0)
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

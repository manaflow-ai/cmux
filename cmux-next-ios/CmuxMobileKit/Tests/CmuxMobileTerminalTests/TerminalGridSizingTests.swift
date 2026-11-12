import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12: "the resizing is so wack when j tap the thijg". The soft
/// keyboard insets the page; it never resizes the Mac's PTY.
@Suite struct TerminalGridSizingTests {
    typealias Size = TerminalResizeSettle.Size
    let resting: CGFloat = 676, top: CGFloat = 62, cell: CGFloat = 16.4

    private func rows(resting: CGFloat? = nil, top: CGFloat? = nil) -> Int {
        TerminalGridSizing.rows(restingStackTop: resting ?? self.resting, chromeTop: top ?? self.top, cellHeight: cell)
    }

    /// One layout pass of the page: what the controller measures and feeds
    /// to the settle. The keyboard moves only `stackTop` (the stack rides it);
    /// the claimed rows read the resting top.
    private struct Page {
        var restingStackTop: CGFloat
        var chromeTop: CGFloat
        var columns: Int
        var stackTop: CGFloat
        func size(cell: CGFloat) -> Size {
            Size(columns: columns, rows: TerminalGridSizing.rows(restingStackTop: restingStackTop, chromeTop: chromeTop, cellHeight: cell))
        }
    }

    @Test func keyboardDownGivesTheRestingRows() {
        #expect(rows() == 37)
    }

    @Test func showingAndHidingTheKeyboardSendsNoResize() {
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

    @Test func repeatedIdenticalSizesSendNothing() {
        var settle = TerminalResizeSettle()
        _ = settle.measured(Size(columns: 53, rows: 37))
        for _ in 0..<10 { #expect(settle.measured(Size(columns: 53, rows: 37)) == .nothing) }
        #expect(settle.settled() == nil)
    }

    @Test func noLiftWhileTheGridFits() {
        #expect(TerminalGridSizing.keyboardLift(gridRows: 37, visibleHeight: 37 * 16, cursorRow: 0, cellHeight: 16) == 0)
    }

    @Test func noLiftWhenTheCursorIsBelowTheClippedTop() {
        // Keyboard up: 20 rows visible of 37; the prompt near the bottom (Claude Code, a shell).
        #expect(TerminalGridSizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: 30, cellHeight: 16) == 0)
        #expect(TerminalGridSizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: 17, cellHeight: 16) == 0)
    }

    @Test func aCursorUnderTheToolbarLiftsTheGridByWholeRows() {
        // vim on line 1 with the keyboard up: 17 rows clipped at the top.
        #expect(TerminalGridSizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: 0, cellHeight: 16) == CGFloat(17 * 16))
        #expect(TerminalGridSizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: 10, cellHeight: 16) == CGFloat(7 * 16))
        // Unknown cursor: the bottom rows stay above the keyboard.
        #expect(TerminalGridSizing.keyboardLift(gridRows: 37, visibleHeight: 20 * 16, cursorRow: nil, cellHeight: 16) == 0)
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

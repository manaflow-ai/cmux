import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// verify/terminal-scroll-model.md: one owner of the scroll position.
@Suite struct TerminalScrollModelTests {
    let cell: CGFloat = 16

    func bottom(_ layout: TerminalDocumentLayout) -> CGFloat {
        TerminalDocumentLayout.bottomOffset(contentHeight: layout.contentHeight(cellHeight: cell), viewportHeight: 874, topInset: 62, bottomInset: 140)
    }

    @Test func followingRidesTheBottomAsOutputAppends() {
        let model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 300)
        let b = TerminalDocumentLayout(originRow: 0, endRow: 320)
        #expect(model.target(layout: a, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(a)) == bottom(a))
        #expect(model.target(layout: b, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(b)) == bottom(b))
    }

    @Test func aReaderStaysOnTheSameRowsWhateverTheDocumentDoes() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        #expect(model.target(layout: a, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(a)) == nil)
        // Released mid-history: row 200 at the top, 5 pt into it.
        model.settled(offsetY: 200 * cell + 5, bottomOffsetY: bottom(a), layout: a, rowHeight: cell)
        #expect(model.state == .reading(.init(row: 200, delta: 5)))
        // Output appends, the TUI's redraw shrinks the end, the top is found lower:
        for layout in [TerminalDocumentLayout(originRow: 0, endRow: 640), TerminalDocumentLayout(originRow: 0, endRow: 560),
                       TerminalDocumentLayout(originRow: 40, endRow: 660)] {
            let y = model.target(layout: layout, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(layout))!
            // The same row stays at the same place on screen.
            #expect(layout.row(atContentY: y, cellHeight: cell) == 200)
            #expect(y - layout.contentY(ofRow: 200, cellHeight: cell) == 5)
        }
    }

    /// "Sometimes the terminal doesn't have bottom content bounciness": a
    /// fling into the bottom follows from there but keeps its rubber band.
    /// The model hands the page back only after the deceleration (its
    /// bounce included) ends; it never asks to stop it.
    @Test func aFlingIntoTheBottomFollowsAndKeepsItsBounce() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        model.scrolled(offsetY: bottom(a) - 400, bottomOffsetY: bottom(a))
        model.scrolled(offsetY: bottom(a) + 30, bottomOffsetY: bottom(a))
        model.flingReachedBottom()
        #expect(model.isFollowing)
        // Output grows during the bounce: the end of the deceleration lands
        // on the new end, whatever offset the bounce stopped at.
        let b = TerminalDocumentLayout(originRow: 0, endRow: 640)
        model.settled(offsetY: bottom(a), bottomOffsetY: bottom(b), layout: b, rowHeight: cell)
        #expect(model.isFollowing)
        #expect(model.target(layout: b, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(b)) == bottom(b))
    }

    @Test func onlyAGestureReachesTheBottom() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        model.settled(offsetY: 100 * cell, bottomOffsetY: bottom(a), layout: a, rowHeight: cell)
        model.flingReachedBottom()
        #expect(!model.isFollowing)
    }

    @Test func releasingNearTheBottomFollows() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        model.settled(offsetY: bottom(a) - 20, bottomOffsetY: bottom(a), layout: a, rowHeight: cell)
        #expect(model.isFollowing)
    }

    /// A fling into the bottom while output streams ends a few rows short of
    /// the newest end: it follows.
    @Test func aFlingThatReachedTheBottomFollows() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        model.scrolled(offsetY: bottom(a), bottomOffsetY: bottom(a))
        let grown = TerminalDocumentLayout(originRow: 0, endRow: 605)
        model.settled(offsetY: bottom(a), bottomOffsetY: bottom(grown), layout: grown, rowHeight: cell)
        #expect(model.isFollowing)
    }

    @Test func onlyInputJumpOrAResetFollowAgain() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        model.settled(offsetY: 100 * cell, bottomOffsetY: bottom(a), layout: a, rowHeight: cell)
        #expect(!model.isFollowing)
        var typed = model; typed.input(); #expect(typed.isFollowing)
        var jumped = model; jumped.jumpToBottom(); #expect(jumped.isFollowing)
        var reset = model; reset.reset(); #expect(reset.isFollowing)
    }

    @Test func aDragThatBeganFollowingRemembersIt() {
        var model = TerminalScrollModel()
        model.began()
        #expect(model.state == .interacting(startedFollowing: true))
        model.keyboardDragPinned()
        #expect(model.isInteracting)
    }

    /// Find: a revealed match is read where it is; output does not move it away, and a
    /// finger on the page wins.
    @Test func findRevealsARowAndKeepsItWhileOutputAppends() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.reveal(row: 120)
        #expect(model.state == .reading(.init(row: 120, delta: 0)))
        let b = TerminalDocumentLayout(originRow: 0, endRow: 700)
        #expect(model.target(layout: b, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(b)) == 120 * cell)
        #expect(model.target(layout: a, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(a)) == 120 * cell)
        // At the document's top, the page starts above row 0 (under the top bar's inset).
        model.reveal(row: 0, delta: -62)
        #expect(model.target(layout: a, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(a)) == -62)
        model.began()
        model.reveal(row: 10)
        #expect(model.isInteracting)
    }
}

/// User report 2026-10-14 (real iPhone): "Jump to bottom only works when
/// scroll acceleration is 0". A tap mid-fling or mid-drag follows, and the
/// end of that gesture (UIKit's deceleration ending, the finger lifting)
/// does not take the page back to reading where it stopped.
@Suite struct TerminalJumpToBottomTests {
    let cell: CGFloat = 16

    @Test(arguments: [0.1, 0.3, 0.6])
    func jumpToBottomMidFlingStaysFollowing(fractionOfHistory: Double) {
        var model = TerminalScrollModel()
        let layout = TerminalDocumentLayout(originRow: 0, endRow: 2000)
        let bottom = TerminalDocumentLayout.bottomOffset(contentHeight: layout.contentHeight(cellHeight: cell), viewportHeight: 874,
                                                         topInset: 62, bottomInset: 140)
        model.began()  // the fling's drag
        model.jumpToBottom()  // the tap while it decelerates
        #expect(model.isFollowing)
        // The deceleration it interrupted ends somewhere in the history.
        model.settled(offsetY: bottom * fractionOfHistory, bottomOffsetY: bottom, layout: layout, rowHeight: cell)
        #expect(model.isFollowing)
        #expect(model.target(layout: layout, rowHeight: cell, topInset: 62, bottomOffsetY: bottom) == bottom)
    }

    @Test func aDragThatBeginsAfterTheJumpStillReads() {
        var model = TerminalScrollModel()
        let layout = TerminalDocumentLayout(originRow: 0, endRow: 2000)
        model.jumpToBottom()
        model.began()
        model.settled(offsetY: 500 * cell, bottomOffsetY: 1900 * cell, layout: layout, rowHeight: cell)
        #expect(model.state == .reading(.init(row: 500, delta: 0)))
    }
}

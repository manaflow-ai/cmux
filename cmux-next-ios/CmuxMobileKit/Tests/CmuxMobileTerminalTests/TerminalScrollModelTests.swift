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

/// #43189, simulator step 86896cb9e08d3fe4de04a693 (trail `PPPPPPNP`): a
/// fling between a history window's reset and its replay's report. The
/// reset follows the old document's bottom; the fling settles there, on the
/// old replay's rows. The report then found the reader's rows in the new
/// 4,000-row window, but `restoreReading` kept the fling's anchor: a row past
/// the window's end, so the page rested on the Mac's screen and the next
/// fling up asked for the newest rows (a fall back to the tail).
@Suite struct TerminalScrollRestoreAfterGestureTests {
    let cell: CGFloat = 16

    func bottom(_ layout: TerminalDocumentLayout) -> CGFloat {
        TerminalDocumentLayout.bottomOffset(contentHeight: layout.contentHeight(cellHeight: cell), viewportHeight: 874, topInset: 62, bottomInset: 140)
    }

    @Test func aGestureSettledBeforeTheReportStillGetsTheReadersRows() {
        var model = TerminalScrollModel()
        // The newest 10,000 rows and the screen; the reset follows its bottom.
        let tail = TerminalDocumentLayout(originRow: 0, endRow: 10_050)
        model.reset()
        model.began()
        model.settled(offsetY: 9_800 * cell, bottomOffsetY: bottom(tail), layout: tail, rowHeight: cell)
        #expect(model.state == .reading(.init(row: 9_800, delta: 0)))
        // The window's replay is in: the reader's rows are at 1,530 of 4,050.
        let window = TerminalDocumentLayout(originRow: 0, endRow: 4_050)
        let reader = TerminalScrollModel.Anchor(row: 1_530, delta: 3)
        #expect(model.restoreReading(reader) == nil)
        #expect(model.state == .reading(reader))
        let y = model.target(layout: window, rowHeight: cell, topInset: 62, bottomOffsetY: bottom(window))
        #expect(y == window.contentY(ofRow: 1_530, cellHeight: cell) + 3)
    }

    /// Simulator step 4a7b618b0ab0733665f972e6 (`T13`): the report came while
    /// a fling held the page and the restore was dropped. The model hands the
    /// reader's rows to the controller, which moves the page under the
    /// gesture; the state stays the gesture's until it settles.
    @Test func aGestureHoldingThePageGetsTheReadersRowsToPlace() {
        var model = TerminalScrollModel()
        model.reset()
        model.began()
        let reader = TerminalScrollModel.Anchor(row: 1_530, delta: 3)
        #expect(model.restoreReading(reader) == reader)
        #expect(model.isInteracting)
    }

    /// Unchanged: no gesture since the reset, the state places the reader.
    @Test func noGestureSinceTheResetReads() {
        var model = TerminalScrollModel()
        model.reset()
        let reader = TerminalScrollModel.Anchor(row: 1_530, delta: 0)
        #expect(model.restoreReading(reader) == nil)
        #expect(model.state == .reading(reader))
    }

    /// Step fdef196a3760133107947747 (`place=f+4058@1656/4151`, then
    /// `newest=4096-4152/gap4111`): the restore set the reader's rows while
    /// the page waited for their frame; the next drag began before the page
    /// got there and took the state, so it started on the Mac's screen. A
    /// drag that begins before the page reached the restored rows gets them,
    /// to put the page there first.
    @Test func aDragBeforeThePageReachedTheRestoredRowsGetsThem() {
        var model = TerminalScrollModel()
        model.reset()
        let reader = TerminalScrollModel.Anchor(row: 1_656, delta: 2)
        model.restoreReading(reader)
        #expect(model.began() == reader)
        #expect(model.isInteracting)
        // Once is enough: the next drag starts wherever this one left the page.
        #expect(model.began() == nil)
    }

    /// The page reached the rows (applyScroll set the offset): a drag starts
    /// where the page is.
    @Test func aDragAfterThePageReachedTheRestoredRowsStartsThere() {
        var model = TerminalScrollModel()
        model.reset()
        model.restoreReading(.init(row: 1_656, delta: 2))
        model.reachedTarget()
        #expect(model.began() == nil)
    }

    /// Steps 23a5dd6f9a59bd5ae686f20a and 29d221e0ad16937d43b3e557 (trail
    /// `...MFN`, `place=h+4058@1545/4151d`, then `newest=4096-4152/gap4111`):
    /// a fling held the page at the old window's bottom when the reader's
    /// rows were found. The controller stopped the fling on them and the
    /// gesture settled there, as plain reading; the page then waited for
    /// the rows' frame showing the frame it had (the Mac's screen), and the
    /// next drag began there. A gesture that settles with nothing moving the
    /// page since the restore rests on the reader's rows, and a drag that
    /// begins before the page reached them gets them.
    @Test func aFlingStoppedOnTheRestoredRowsKeepsThemForTheNextDrag() {
        var model = TerminalScrollModel()
        let window = TerminalDocumentLayout(originRow: 0, endRow: 4_151)
        model.reset()
        model.began()
        let reader = TerminalScrollModel.Anchor(row: 1_545, delta: 3)
        #expect(model.restoreReading(reader) == reader)
        // The controller put the page on the rows and stopped the fling.
        model.settled(offsetY: window.contentY(ofRow: 1_545, cellHeight: cell) + 3, bottomOffsetY: bottom(window),
                      layout: window, rowHeight: cell)
        #expect(model.state == .reading(reader))
        #expect(model.awaitsPlacement)
        // The next drag begins before the page reached the rows' frame.
        #expect(model.began() == reader)
    }

    /// The same, with the page off the rows when the gesture settles (moved
    /// for the frame it waits for): the reader's rows, not the offset's.
    @Test func aFlingStoppedOnTheRestoredRowsReadsThemWhereverThePageWaits() {
        var model = TerminalScrollModel()
        let window = TerminalDocumentLayout(originRow: 0, endRow: 4_151)
        model.reset()
        model.began()
        let reader = TerminalScrollModel.Anchor(row: 1_545, delta: 0)
        model.restoreReading(reader)
        model.settled(offsetY: window.contentY(ofRow: 4_096, cellHeight: cell), bottomOffsetY: bottom(window),
                      layout: window, rowHeight: cell)
        #expect(model.state == .reading(reader))
    }

    /// A finger that moves the page after the restore reads where it left it.
    @Test func aFingerThatMovesAfterTheRestoreReadsWhereItLeftThePage() {
        var model = TerminalScrollModel()
        let window = TerminalDocumentLayout(originRow: 0, endRow: 4_151)
        model.reset()
        model.began()
        model.restoreReading(.init(row: 1_545, delta: 0))
        model.scrolled(offsetY: window.contentY(ofRow: 1_500, cellHeight: cell), bottomOffsetY: bottom(window))
        model.settled(offsetY: window.contentY(ofRow: 1_500, cellHeight: cell), bottomOffsetY: bottom(window),
                      layout: window, rowHeight: cell)
        #expect(model.state == .reading(.init(row: 1_500, delta: 0)))
        #expect(!model.awaitsPlacement)
    }

    /// Leo, 2026-11-22: "zoming in and out eith the magnifying glass layout
    /// shifts unnecessarily when resizing". The anchor is the row at the
    /// bounds' top, behind the 62 pt toolbar; a new row height keeps the
    /// first row below the toolbar (and how far into it) instead.
    @Test func aZoomKeepsTheFirstRowBelowTheToolbar() {
        var model = TerminalScrollModel()
        let a = TerminalDocumentLayout(originRow: 0, endRow: 600)
        model.began()
        // Row 200 at the bounds' top, 4 pt into it: 66 pt down is row 204, 2 pt in.
        model.settled(offsetY: 200 * cell + 4, bottomOffsetY: bottom(a), layout: a, rowHeight: cell)
        func firstVisible(_ rowHeight: CGFloat) -> (row: Int, into: CGFloat) {
            let y = model.target(layout: a, rowHeight: rowHeight, topInset: 62, bottomOffsetY: .greatestFiniteMagnitude)! + 62
            let row = a.row(atContentY: y, cellHeight: rowHeight)
            return (row, y - a.contentY(ofRow: row, cellHeight: rowHeight))
        }
        #expect(firstVisible(cell).row == 204)
        #expect(abs(firstVisible(cell).into - 2) < 0.001)
        // Zoom in to 20 pt rows: still row 204, the same fraction into it.
        model.rowHeightChanged(from: cell, to: 20, topInset: 62)
        #expect(firstVisible(20).row == 204)
        #expect(abs(firstVisible(20).into - 2.5) < 0.001)
        // And out to 12 pt rows.
        model.rowHeightChanged(from: 20, to: 12, topInset: 62)
        #expect(firstVisible(12).row == 204)
        #expect(abs(firstVisible(12).into - 1.5) < 0.001)
    }

    @Test func aZoomLeavesFollowingAlone() {
        var model = TerminalScrollModel()
        model.rowHeightChanged(from: 16, to: 20, topInset: 62)
        #expect(model.isFollowing)
    }

    /// At the top of the document the first row stays row 0 at the inset.
    @Test func aZoomAtTheTopStaysAtTheTop() {
        var model = TerminalScrollModel()
        model.reveal(row: 0, delta: -62)
        model.rowHeightChanged(from: 16, to: 20, topInset: 62)
        #expect(model.state == .reading(.init(row: 0, delta: -62)))
    }
}

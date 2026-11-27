import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

/// Where a shared grid sits on the phone and what stays visible when the
/// keyboard opens. Viewport: 400×600 below a 100 pt navigation bar; cells
/// are 20 pt tall; the keyboard intrusion (keyboard minus the resting safe
/// area) is 300 pt.
@Suite struct TerminalKeyboardViewportTests {
    private let viewport = CGRect(x: 0, y: 100, width: 400, height: 600)
    private let cellHeight: CGFloat = 20
    private let intrusion: CGFloat = 300

    // MARK: Letterbox pin

    /// "If it's too short, it should stick to top": a grid at least a row
    /// shorter than the viewport pins to the top, with the slack below it.
    @Test func shortGridPinsToTheTop() {
        let rect = TerminalLetterboxGeometry.renderRect(
            renderSize: CGSize(width: 300, height: 400), in: viewport, cellHeight: cellHeight
        )
        #expect(rect == CGRect(x: 0, y: 100, width: 300, height: 400))
    }

    /// The natural grid leaves less than one row of remainder: it keeps
    /// riding the dock, with the remainder above it under the top band.
    @Test func naturalGridRemainderStaysBottomPinned() {
        let rect = TerminalLetterboxGeometry.renderRect(
            renderSize: CGSize(width: 400, height: 590), in: viewport, cellHeight: cellHeight
        )
        #expect(rect == CGRect(x: 0, y: 110, width: 400, height: 590))
    }

    /// An unmeasured cell height never top-pins a full-height render.
    @Test func unknownCellHeightStaysBottomPinned() {
        let rect = TerminalLetterboxGeometry.renderRect(
            renderSize: CGSize(width: 400, height: 590), in: viewport, cellHeight: 0
        )
        #expect(rect.maxY == viewport.maxY)
    }

    // MARK: Keyboard

    /// A short top-pinned grid whose cursor row sits above the keyboard: the
    /// grid does not move, and the chrome's viewport ends at the dock.
    @Test func keyboardOpenWithAGridThatFitsKeepsItTopPinned() {
        let grid = CGRect(x: 0, y: 100, width: 300, height: 200) // 10 rows
        let blank = TerminalLetterboxGeometry.blankBelowContent(
            renderRect: grid, viewportRect: viewport, contentBottom: 200, displayScale: 1
        )
        #expect(blank == 400)
        let keyboard = TerminalKeyboardViewport(viewportRect: viewport, intrusion: intrusion, blankBelowContent: blank)
        #expect(keyboard.slide == 0)
        #expect(keyboard.visibleRect == CGRect(x: 0, y: 100, width: 400, height: 300))
        #expect(keyboard.visibleRect.contains(grid))
    }

    /// A grid taller than the space above the keyboard with the prompt on
    /// its last row: it slides up just enough to keep that row visible.
    @Test func keyboardOpenWithAGridThatDoesNotFitKeepsTheCursorRowVisible() {
        let grid = CGRect(x: 0, y: 100, width: 300, height: 500) // 25 rows
        let cursorRowBottom: CGFloat = 500
        let blank = TerminalLetterboxGeometry.blankBelowContent(
            renderRect: grid, viewportRect: viewport, contentBottom: cursorRowBottom, displayScale: 1
        )
        #expect(blank == 100)
        let keyboard = TerminalKeyboardViewport(viewportRect: viewport, intrusion: intrusion, blankBelowContent: blank)
        // Least movement: the 100 pt below the grid absorbs part of the
        // intrusion, the render slides the remaining 200 pt.
        #expect(keyboard.slide == 200)
        // In surface coordinates the dock now covers everything below the
        // cursor row, so the row's bottom is exactly the visible bottom.
        #expect(keyboard.visibleRect.maxY == grid.minY + cursorRowBottom)
        #expect(keyboard.visibleRect.minY == viewport.minY)
    }

    /// A cursor mid-grid with blank rows under it: those rows absorb the
    /// keyboard first, so the render moves less than the intrusion.
    @Test func blankRowsUnderTheCursorAbsorbTheKeyboardFirst() {
        let grid = CGRect(x: 0, y: 100, width: 300, height: 500)
        let blank = TerminalLetterboxGeometry.blankBelowContent(
            renderRect: grid, viewportRect: viewport, contentBottom: 300, displayScale: 1
        )
        #expect(blank == 300)
        let keyboard = TerminalKeyboardViewport(viewportRect: viewport, intrusion: intrusion, blankBelowContent: blank)
        #expect(keyboard.slide == 0)
        #expect(keyboard.visibleRect.maxY == 400)
    }

    /// Scaled to fit (0.5×) and top-pinned: content bottoms scale with the
    /// display, and the chrome's viewport still ends at the dock.
    @Test func scaledGridWithTheKeyboard() {
        let layout = TerminalScaledGridLayout(gridSize: CGSize(width: 800, height: 900), viewport: viewport)
        #expect(layout.displayScale == 0.5)
        #expect(layout.displayRect == CGRect(x: 0, y: 100, width: 400, height: 450))
        // The cursor is on the grid's last row (render-local 900 pt).
        let blank = TerminalLetterboxGeometry.blankBelowContent(
            renderRect: layout.displayRect, viewportRect: viewport, contentBottom: 900,
            displayScale: layout.displayScale
        )
        #expect(blank == 150)
        let keyboard = TerminalKeyboardViewport(viewportRect: viewport, intrusion: intrusion, blankBelowContent: blank)
        #expect(keyboard.slide == 150)
        #expect(keyboard.visibleRect.maxY == layout.displayRect.maxY)

        // The chrome then draws no border line on the dock and no hatch or
        // chip under it.
        let geometry = TerminalSizingBoundsDecoration(
            gridColumns: 120, gridRows: 40, viewerColumns: 60, viewerRows: 30
        ).geometry(viewportRect: keyboard.visibleRect, renderRect: layout.displayRect)
        #expect(geometry.borderEdges.isEmpty)
        #expect(geometry.hatchRects.allSatisfy { $0.maxY <= keyboard.visibleRect.maxY })
    }

    /// Unknown content (alternate screen): nothing absorbs, the render rides
    /// the dock by the full intrusion.
    @Test func unknownContentRidesTheDock() {
        let keyboard = TerminalKeyboardViewport(viewportRect: viewport, intrusion: intrusion, blankBelowContent: nil)
        #expect(keyboard.slide == intrusion)
        #expect(keyboard.visibleRect == viewport)
    }

    /// A scroll-top reveal slides the render back down; the dock then covers
    /// that much more of it.
    @Test func scrollTopRevealCoversMoreOfTheViewport() {
        let keyboard = TerminalKeyboardViewport(
            viewportRect: viewport, intrusion: intrusion, blankBelowContent: 100, scrollTopReveal: 50
        )
        #expect(keyboard.slide == 150)
        #expect(keyboard.visibleRect.maxY == viewport.maxY - 150)
    }

    @Test func keyboardDownChangesNothing() {
        let keyboard = TerminalKeyboardViewport(viewportRect: viewport, intrusion: 0, blankBelowContent: 400)
        #expect(keyboard.slide == 0)
        #expect(keyboard.visibleRect == viewport)
    }
}

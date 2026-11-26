import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

/// The size chip must never cover grid content, above all the last row where
/// the prompt and cursor live. It sits in the letterbox outside the grid, and
/// only when the grid fills the viewport does it shrink to a compact pill at
/// the viewport's top-trailing corner.
@Suite struct TerminalSizingChipPlacementTests {
    private let viewport = CGRect(x: 0, y: 100, width: 400, height: 600)
    private let chip = CGSize(width: 180, height: 24)
    private let compact = CGSize(width: 60, height: 24)

    private func place(grid: CGRect) -> TerminalSizingChipPlacement {
        TerminalSizingChipPlacement.place(
            chipSize: chip,
            compactChipSize: compact,
            gridRect: grid,
            viewportRect: viewport
        )
    }

    @Test func roomBelowTheGridPutsTheChipUnderItsTrailingCorner() {
        let grid = CGRect(x: 0, y: 100, width: 300, height: 400)
        let placement = place(grid: grid)
        #expect(placement.anchor == .belowGrid)
        #expect(!placement.isCompact)
        #expect(placement.frame.minY >= grid.maxY)
        #expect(placement.frame.maxX == grid.maxX)
        #expect(viewport.contains(placement.frame))
    }

    @Test func bottomPinnedGridWithTrailingRoomPutsTheChipBesideTheLastRows() {
        // A narrow grid pinned to the bottom-left of a wide phone.
        let grid = CGRect(x: 0, y: 300, width: 200, height: 400)
        let placement = place(grid: grid)
        #expect(placement.anchor == .besideGrid)
        #expect(placement.frame.minX >= grid.maxX)
        #expect(placement.frame.maxY == grid.maxY)
        #expect(viewport.contains(placement.frame))
    }

    @Test func bottomPinnedFullWidthGridPutsTheChipAboveIt() {
        // The exact screenshot shape: full width, pinned to the dock, slack
        // above. The chip went over the last row's trailing cells.
        let grid = CGRect(x: 0, y: 300, width: 400, height: 400)
        let placement = place(grid: grid)
        #expect(placement.anchor == .aboveGrid)
        #expect(placement.frame.maxY <= grid.minY)
        // Trailing-aligned, kept one inset inside the viewport edge.
        #expect(placement.frame.maxX == viewport.maxX - TerminalSizingChipPlacement.defaultInset)
        #expect(!placement.frame.intersects(grid))
    }

    @Test func gridFillingTheViewportUsesACompactPillAtTheTopTrailingCorner() {
        let placement = place(grid: viewport)
        #expect(placement.anchor == .viewportTopTrailing)
        #expect(placement.isCompact)
        #expect(placement.frame.size == compact)
        #expect(placement.frame.minY < viewport.midY)
        #expect(placement.frame.maxX <= viewport.maxX)
        #expect(viewport.contains(placement.frame))
    }

    @Test func theChipNeverCoversTheLastRow() {
        let rowHeight: CGFloat = 16
        let grids = [
            CGRect(x: 0, y: 100, width: 300, height: 400),
            CGRect(x: 0, y: 300, width: 200, height: 400),
            CGRect(x: 0, y: 300, width: 400, height: 400),
            viewport,
            CGRect(x: 0, y: 110, width: 400, height: 590),
        ]
        for grid in grids {
            let lastRow = CGRect(x: grid.minX, y: grid.maxY - rowHeight, width: grid.width, height: rowHeight)
            #expect(!place(grid: grid).frame.intersects(lastRow), "grid \(grid)")
        }
    }

    @Test func aWideChipIsClampedInsideTheViewport() {
        let wide = TerminalSizingChipPlacement.place(
            chipSize: CGSize(width: 900, height: 24),
            compactChipSize: compact,
            gridRect: CGRect(x: 0, y: 100, width: 300, height: 400),
            viewportRect: viewport
        )
        #expect(viewport.contains(wide.frame))
    }
}

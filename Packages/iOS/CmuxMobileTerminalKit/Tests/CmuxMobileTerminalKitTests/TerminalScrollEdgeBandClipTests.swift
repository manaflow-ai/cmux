import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

/// The renderer's drawable extends above the grid by the top scroll-edge band,
/// which libghostty fills with the scrollback rows just above the viewport.
/// The band belongs under the navigation bar, above the viewport. When the
/// displayed grid starts below the viewport's top edge (a shared grid scaled
/// to fit, or a letterbox), the band would land in the unused viewport area
/// the sizing chrome hatches and puts the chip in, so scrollback rows showed
/// under the chip. Measurements are the iPhone 17 Pro repro: Fixed 120x40 on
/// a 66x41 phone with a 198 pt top band.
@Suite struct TerminalScrollEdgeBandClipTests {
    private let viewport = CGRect(x: 0, y: 198, width: 402, height: 482)
    private let gridSize = CGSize(width: 726, height: 470)
    private let topInset: CGFloat = 198
    private let bottomInset: CGFloat = 78

    private var layerSize: CGSize {
        CGSize(width: gridSize.width, height: gridSize.height + topInset + bottomInset)
    }

    /// A scaled grid shorter than the viewport is top-pinned: the top band
    /// sits under the navigation bar as usual, and the bottom band would
    /// render the rows below the grid in the unused area, so it is hidden.
    @Test func topPinnedScaledGridHidesOnlyTheBottomBand() throws {
        let layout = TerminalScaledGridLayout(gridSize: gridSize, viewport: viewport)
        #expect(layout.isScaled)
        #expect(layout.displayRect.minY == viewport.minY)
        #expect(layout.displayRect.maxY < viewport.maxY)

        let visible = try #require(TerminalScrollEdgeBandClip(topInset: topInset, bottomInset: bottomInset).visibleLayerRect(
            layerSize: layerSize,
            gridDisplayRect: layout.displayRect,
            viewportRect: viewport
        ))
        // Layer-local, unscaled: everything down to the grid's last row.
        #expect(visible == CGRect(x: 0, y: 0, width: layerSize.width, height: topInset + gridSize.height))
    }

    @Test func topPinnedScaledGridPutsTheChipBelowTheGrid() throws {
        let layout = TerminalScaledGridLayout(gridSize: gridSize, viewport: viewport)
        let decoration = TerminalSizingBoundsDecoration(
            gridColumns: 120, gridRows: 40, viewerColumns: 66, viewerRows: 41
        )
        let geometry = decoration.geometry(viewportRect: viewport, renderRect: layout.displayRect)
        let border = try #require(geometry.borderRect)
        #expect(abs(border.minY - layout.displayRect.minY) < 0.001)
        #expect(abs(border.height - layout.displayRect.height) < 0.001)
        #expect(geometry.borderEdges == [.bottom])

        let placement = TerminalSizingChipPlacement.place(
            chipSize: CGSize(width: 190, height: 24),
            compactChipSize: CGSize(width: 70, height: 24),
            gridRect: layout.displayRect,
            viewportRect: viewport
        )
        #expect(placement.anchor == .belowGrid)
        #expect(!placement.frame.intersects(layout.displayRect))
    }

    @Test func letterboxedGridBelowTheViewportTopHidesTheTopBand() {
        let grid = CGRect(x: 0, y: 400, width: 300, height: 280)
        let size = CGSize(width: 300, height: 280 + topInset + bottomInset)
        let visible = TerminalScrollEdgeBandClip(topInset: topInset, bottomInset: bottomInset).visibleLayerRect(
            layerSize: size,
            gridDisplayRect: grid,
            viewportRect: viewport
        )
        #expect(visible == CGRect(x: 0, y: topInset, width: size.width, height: size.height - topInset))
    }

    @Test func gridReachingTheViewportTopKeepsTheWholeBand() {
        // Natural grid, and the keyboard top-align path: the grid's top row
        // is the viewport top, so the band sits under the navigation bar.
        let grid = CGRect(x: 0, y: viewport.minY, width: 402, height: 482)
        #expect(TerminalScrollEdgeBandClip(topInset: topInset, bottomInset: bottomInset).visibleLayerRect(
            layerSize: CGSize(width: 402, height: 482 + topInset + bottomInset),
            gridDisplayRect: grid,
            viewportRect: viewport
        ) == nil)
    }

    @Test func magnifiedGridPastTheViewportTopKeepsTheWholeBand() {
        // A tall grid (120x80) magnified until it overflows the viewport.
        let tall = CGSize(width: 726, height: 940)
        let layout = TerminalScaledGridLayout(
            gridSize: tall,
            viewport: viewport,
            magnification: 10,
            offset: .zero
        )
        #expect(layout.displayRect.minY < viewport.minY)
        #expect(TerminalScrollEdgeBandClip(topInset: topInset, bottomInset: bottomInset).visibleLayerRect(
            layerSize: CGSize(width: tall.width, height: tall.height + topInset + bottomInset),
            gridDisplayRect: layout.displayRect,
            viewportRect: viewport
        ) == nil)
    }

    @Test func noTopBandNeedsNoClip() {
        let layout = TerminalScaledGridLayout(gridSize: gridSize, viewport: viewport)
        #expect(TerminalScrollEdgeBandClip(topInset: 0, bottomInset: 0).visibleLayerRect(
            layerSize: gridSize,
            gridDisplayRect: layout.displayRect,
            viewportRect: viewport
        ) == nil)
    }

    /// A top-pinned letterbox (a shared grid shorter than the phone) keeps
    /// the top band and hides the bottom band below the grid.
    @Test func topPinnedLetterboxHidesTheBottomBand() {
        let grid = CGRect(x: 0, y: viewport.minY, width: 300, height: 280)
        let size = CGSize(width: 300, height: 280 + topInset + bottomInset)
        #expect(TerminalScrollEdgeBandClip(topInset: topInset, bottomInset: bottomInset).visibleLayerRect(
            layerSize: size,
            gridDisplayRect: grid,
            viewportRect: viewport
        ) == CGRect(x: 0, y: 0, width: 300, height: topInset + 280))
    }
}

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

    @Test func scaledGridBelowTheViewportTopHidesTheTopBand() throws {
        let layout = TerminalScaledGridLayout(gridSize: gridSize, viewport: viewport)
        #expect(layout.isScaled)
        #expect(layout.displayRect.minY > viewport.minY)

        let visible = try #require(TerminalScrollEdgeBandClip.visibleLayerRect(
            layerSize: layerSize,
            topInset: topInset,
            gridDisplayRect: layout.displayRect,
            viewportRect: viewport
        ))
        // Layer-local, unscaled: everything from the grid's top row down.
        #expect(visible == CGRect(x: 0, y: topInset, width: layerSize.width, height: layerSize.height - topInset))

        // Mapped to the view, the visible part starts exactly at the
        // displayed grid, so nothing renders in the slack above it.
        let scale = layout.displayScale
        let layerTopInView = layout.displayRect.minY - topInset * scale
        #expect(abs(layerTopInView + visible.minY * scale - layout.displayRect.minY) < 0.001)
    }

    @Test func scaledGridKeepsTheChipAndBorderOnTheDisplayedGrid() throws {
        let layout = TerminalScaledGridLayout(gridSize: gridSize, viewport: viewport)
        let decoration = TerminalSizingBoundsDecoration(
            gridColumns: 120, gridRows: 40, viewerColumns: 66, viewerRows: 41
        )
        let geometry = decoration.geometry(viewportRect: viewport, renderRect: layout.displayRect)
        let border = try #require(geometry.borderRect)
        #expect(abs(border.minX - layout.displayRect.minX) < 0.001)
        #expect(abs(border.minY - layout.displayRect.minY) < 0.001)
        #expect(abs(border.width - layout.displayRect.width) < 0.001)
        #expect(abs(border.height - layout.displayRect.height) < 0.001)

        let placement = TerminalSizingChipPlacement.place(
            chipSize: CGSize(width: 190, height: 24),
            compactChipSize: CGSize(width: 70, height: 24),
            gridRect: layout.displayRect,
            viewportRect: viewport
        )
        #expect(placement.anchor == .aboveGrid)
        #expect(!placement.frame.intersects(layout.displayRect))
        // The chip sits where the top band would have rendered scrollback.
        let bandInView = CGRect(
            x: layout.displayRect.minX,
            y: layout.displayRect.minY - topInset * layout.displayScale,
            width: layout.displayRect.width,
            height: topInset * layout.displayScale
        )
        #expect(placement.frame.intersects(bandInView))
    }

    @Test func letterboxedGridBelowTheViewportTopHidesTheTopBand() {
        let grid = CGRect(x: 0, y: 400, width: 300, height: 280)
        let size = CGSize(width: 300, height: 280 + topInset + bottomInset)
        let visible = TerminalScrollEdgeBandClip.visibleLayerRect(
            layerSize: size,
            topInset: topInset,
            gridDisplayRect: grid,
            viewportRect: viewport
        )
        #expect(visible == CGRect(x: 0, y: topInset, width: size.width, height: size.height - topInset))
    }

    @Test func gridReachingTheViewportTopKeepsTheWholeBand() {
        // Natural grid, and the keyboard top-align path: the grid's top row
        // is the viewport top, so the band sits under the navigation bar.
        let grid = CGRect(x: 0, y: viewport.minY, width: 402, height: 482)
        #expect(TerminalScrollEdgeBandClip.visibleLayerRect(
            layerSize: CGSize(width: 402, height: 482 + topInset + bottomInset),
            topInset: topInset,
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
        #expect(TerminalScrollEdgeBandClip.visibleLayerRect(
            layerSize: CGSize(width: tall.width, height: tall.height + topInset + bottomInset),
            topInset: topInset,
            gridDisplayRect: layout.displayRect,
            viewportRect: viewport
        ) == nil)
    }

    @Test func noTopBandNeedsNoClip() {
        let layout = TerminalScaledGridLayout(gridSize: gridSize, viewport: viewport)
        #expect(TerminalScrollEdgeBandClip.visibleLayerRect(
            layerSize: gridSize,
            topInset: 0,
            gridDisplayRect: layout.displayRect,
            viewportRect: viewport
        ) == nil)
    }
}

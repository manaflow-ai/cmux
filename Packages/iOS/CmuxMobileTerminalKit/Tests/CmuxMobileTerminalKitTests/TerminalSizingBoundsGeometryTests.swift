import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

@Suite struct TerminalSizingBoundsGeometryTests {
    private let viewport = CGRect(x: 0, y: 0, width: 400, height: 600)

    @Test func matchingViewportDrawsNothing() {
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 50, gridRows: 40, viewerColumns: 50, viewerRows: 40,
            viewportRect: viewport, renderRect: CGRect(x: 0, y: 2, width: 398, height: 598)
        )
        #expect(geometry.borderRect == nil)
        #expect(geometry.hatchRects.isEmpty)
        #expect(geometry.cutFades.isEmpty)
    }

    /// Larger phone: the letterbox pins a smaller grid to the bottom-left, so
    /// the hatch fills the top band and the trailing band.
    @Test func largerViewerHatchesTopAndTrailing() {
        let grid = CGRect(x: 0, y: 200, width: 300, height: 400)
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 30, gridRows: 20, viewerColumns: 40, viewerRows: 30,
            viewportRect: viewport, renderRect: grid
        )
        #expect(geometry.borderRect == grid)
        #expect(geometry.hatchRects == [
            CGRect(x: 0, y: 0, width: 400, height: 200),
            CGRect(x: 300, y: 200, width: 100, height: 400),
        ])
        #expect(geometry.cutFades.isEmpty)
        #expect(geometry.hiddenColumns == 0)
        #expect(geometry.hiddenRows == 0)
    }

    /// A magnified grid runs past the trailing and top edges.
    @Test func smallerViewerFadesCutEdges() {
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 118, gridRows: 38, viewerColumns: 50, viewerRows: 30,
            viewportRect: viewport, renderRect: CGRect(x: 0, y: -100, width: 900, height: 700)
        )
        #expect(geometry.borderRect == viewport)
        #expect(geometry.hatchRects.isEmpty)
        #expect(geometry.hiddenColumns == 68)
        #expect(geometry.hiddenRows == 8)
        #expect(geometry.cutFades.map(\.edge) == [.trailing, .top])
        let depth = TerminalSizingBoundsGeometry.cutFadeDepth
        #expect(geometry.cutFades[0].rect == CGRect(x: 400 - depth, y: 0, width: depth, height: 600))
        #expect(geometry.cutFades[1].rect == CGRect(x: 0, y: 0, width: 400, height: depth))
    }

    /// A wider grid scaled to the viewport width shows whole: no cut edge,
    /// hatch above the bottom-pinned grid.
    @Test func widerGridScaledToFitHasNoCutEdge() {
        let grid = CGRect(x: 0, y: 350, width: 400, height: 250)
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 80, gridRows: 25, viewerColumns: 50, viewerRows: 30,
            viewportRect: viewport, renderRect: grid
        )
        #expect(geometry.hiddenColumns == 30)
        #expect(geometry.hiddenRows == 0)
        #expect(geometry.cutFades.isEmpty)
        #expect(geometry.hatchRects == [CGRect(x: 0, y: 0, width: 400, height: 350)])
    }

    /// A magnified grid panned to its middle is cut on all four edges.
    @Test func pannedMagnifiedGridFadesEveryCutEdge() {
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 175, gridRows: 78, viewerColumns: 50, viewerRows: 30,
            viewportRect: viewport, renderRect: CGRect(x: -200, y: -100, width: 1000, height: 900)
        )
        #expect(geometry.borderRect == viewport)
        #expect(geometry.hatchRects.isEmpty)
        #expect(geometry.cutFades.map(\.edge) == [.trailing, .leading, .top, .bottom])
    }

    @Test func decorationBuildsTheSameGeometry() {
        let decoration = TerminalSizingBoundsDecoration(
            gridColumns: 30, gridRows: 20, viewerColumns: 40, viewerRows: 30
        )
        let grid = CGRect(x: 0, y: 200, width: 300, height: 400)
        #expect(decoration.geometry(viewportRect: viewport, renderRect: grid) == TerminalSizingBoundsGeometry(
            gridColumns: 30, gridRows: 20, viewerColumns: 40, viewerRows: 30,
            viewportRect: viewport, renderRect: grid
        ))
    }

    // MARK: Border edges

    /// Flush with the viewport top (under the navigation bar), smaller on the
    /// trailing and bottom sides: no top or leading line.
    @Test func topPinnedGridDrawsTrailingAndBottomOnly() {
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 30, gridRows: 20, viewerColumns: 40, viewerRows: 30,
            viewportRect: viewport, renderRect: CGRect(x: 0, y: 0, width: 300, height: 400)
        )
        #expect(geometry.borderEdges == [.trailing, .bottom])
    }

    /// A smaller grid pinned to the bottom-leading corner: top and trailing.
    @Test func bottomLeadingPinnedGridDrawsTopAndTrailing() {
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 30, gridRows: 20, viewerColumns: 40, viewerRows: 30,
            viewportRect: viewport, renderRect: CGRect(x: 0, y: 200, width: 300, height: 400)
        )
        #expect(geometry.borderEdges == [.top, .trailing])
    }

    /// A wider grid scaled to the width and bottom-pinned: only the top.
    @Test func scaledBottomPinnedGridDrawsTopOnly() {
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 80, gridRows: 25, viewerColumns: 50, viewerRows: 30,
            viewportRect: viewport, renderRect: CGRect(x: 0, y: 350, width: 400, height: 250)
        )
        #expect(geometry.borderEdges == [.top])
    }

    /// A cut grid fills the viewport: no border, the viewport edges are
    /// already bounded by the navigation bar and the screen.
    @Test func gridFillingViewportDrawsNoEdge() {
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 118, gridRows: 38, viewerColumns: 50, viewerRows: 30,
            viewportRect: viewport, renderRect: CGRect(x: 0, y: -100, width: 900, height: 700)
        )
        #expect(geometry.borderEdges.isEmpty)
    }

    @Test func matchingViewportDrawsNoEdge() {
        let geometry = TerminalSizingBoundsGeometry(
            gridColumns: 50, gridRows: 40, viewerColumns: 50, viewerRows: 40,
            viewportRect: viewport, renderRect: viewport
        )
        #expect(geometry.borderEdges.isEmpty)
    }

    @Test func edgesSkipSidesFlushWithinOnePoint() {
        #expect(TerminalSizingBorderEdges(rect: CGRect(x: 0.5, y: 0.8, width: 300, height: 599), in: viewport) == [.trailing])
        #expect(TerminalSizingBorderEdges(rect: viewport, in: viewport).isEmpty)
    }

    /// Adjacent edges join into one open polyline, so corners stay clean.
    @Test func edgesFormOpenPolylines() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(TerminalSizingBorderEdges([.trailing, .bottom]).polylines(around: rect)
            == [[CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)]])
        #expect(TerminalSizingBorderEdges([.top, .trailing]).polylines(around: rect)
            == [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50)]])
        #expect(TerminalSizingBorderEdges([.top, .bottom]).polylines(around: rect)
            == [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], [CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)]])
        #expect(TerminalSizingBorderEdges([.top, .trailing, .bottom, .leading]).polylines(around: rect)
            == [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 0)]])
    }
}

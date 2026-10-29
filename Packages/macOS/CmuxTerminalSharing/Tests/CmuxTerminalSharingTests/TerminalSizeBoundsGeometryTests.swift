import CmuxTerminalSharing
import CmuxTerminalSizing
import CoreGraphics
import Testing

@Suite struct TerminalSizeBoundsGeometryTests {
    private let cell = CGSize(width: 16, height: 34)

    @Test func smallerGridShowsBoundsWithoutCrop() {
        let g = TerminalSizeBoundsGeometry(
            paneSize: CGSize(width: 1000, height: 600),
            surfacePixelSize: CGSize(width: 50 * 16 + 4, height: 30 * 34 + 4),
            cellPixelSize: cell, scale: 2, grid: TerminalGridSize(cols: 50, rows: 30)
        )
        #expect(g.showsBounds)
        #expect(g.hiddenColumns == 0 && g.hiddenRows == 0)
        #expect(g.gridRect == CGRect(x: 0, y: 0, width: 402, height: 512))
    }

    @Test func matchingGridNeedsNoDecoration() {
        let g = TerminalSizeBoundsGeometry(
            paneSize: CGSize(width: 402, height: 512),
            surfacePixelSize: CGSize(width: 804, height: 1024),
            cellPixelSize: cell, scale: 2, grid: TerminalGridSize(cols: 50, rows: 30)
        )
        #expect(!g.needsDecoration)
    }

    @Test func widerGridCountsCutOffColumns() {
        let g = TerminalSizeBoundsGeometry(
            paneSize: CGSize(width: 400, height: 512),
            surfacePixelSize: CGSize(width: 120 * 16, height: 1024),
            cellPixelSize: cell, scale: 2, grid: TerminalGridSize(cols: 120, rows: 30)
        )
        #expect(g.hiddenColumns == 70)
        #expect(g.gridRect.width == 400)
    }

    // MARK: Border edges

    /// The grid pins top-left under the tab bar, whose separator already
    /// draws the top line: the border draws only trailing and bottom.
    @Test func topLeftPinnedGridDrawsNoTopOrLeadingEdge() {
        let g = TerminalSizeBoundsGeometry(
            paneSize: CGSize(width: 1000, height: 600),
            surfacePixelSize: CGSize(width: 50 * 16 + 4, height: 30 * 34 + 4),
            cellPixelSize: cell, scale: 2, grid: TerminalGridSize(cols: 50, rows: 30)
        )
        #expect(g.borderEdges == [.trailing, .bottom])
        #expect(!g.borderEdges.contains(.top))
    }

    /// Only narrower: the bottom edge is flush with the pane, so only trailing.
    @Test func narrowerFullHeightGridDrawsTrailingOnly() {
        let g = TerminalSizeBoundsGeometry(
            paneSize: CGSize(width: 1000, height: 512),
            surfacePixelSize: CGSize(width: 804, height: 1024),
            cellPixelSize: cell, scale: 2, grid: TerminalGridSize(cols: 50, rows: 30)
        )
        #expect(g.borderEdges == [.trailing])
    }

    @Test func matchingGridDrawsNoEdge() {
        let g = TerminalSizeBoundsGeometry(
            paneSize: CGSize(width: 402, height: 512),
            surfacePixelSize: CGSize(width: 804, height: 1024),
            cellPixelSize: cell, scale: 2, grid: TerminalGridSize(cols: 50, rows: 30)
        )
        #expect(g.borderEdges.isEmpty)
    }

    /// A cropped grid fills the pane on every side: no border line at all.
    @Test func croppedGridDrawsNoEdge() {
        let g = TerminalSizeBoundsGeometry(
            paneSize: CGSize(width: 400, height: 512),
            surfacePixelSize: CGSize(width: 120 * 16, height: 1024),
            cellPixelSize: cell, scale: 2, grid: TerminalGridSize(cols: 120, rows: 30)
        )
        #expect(g.borderEdges.isEmpty)
    }

    @Test func edgesSkipSidesFlushWithinOnePoint() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 600)
        #expect(TerminalSizeBoundsEdges(rect: CGRect(x: 0.5, y: 0, width: 300, height: 599.2), in: viewport) == [.trailing])
        #expect(TerminalSizeBoundsEdges(rect: CGRect(x: 0, y: 300, width: 400, height: 300), in: viewport) == [.top])
        #expect(TerminalSizeBoundsEdges(rect: viewport, in: viewport).isEmpty)
    }

    /// Trailing and bottom join into one open polyline, so the corner is clean
    /// and the top and leading sides stay undrawn.
    @Test func trailingAndBottomFormOneOpenPolyline() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let lines = TerminalSizeBoundsEdges([.trailing, .bottom]).polylines(around: rect)
        #expect(lines == [[CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)]])
        #expect(TerminalSizeBoundsEdges([.top]).polylines(around: rect) == [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]])
        #expect(TerminalSizeBoundsEdges().polylines(around: rect).isEmpty)
        #expect(TerminalSizeBoundsEdges([.leading, .top]).polylines(around: rect)
            == [[CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]])
    }
}

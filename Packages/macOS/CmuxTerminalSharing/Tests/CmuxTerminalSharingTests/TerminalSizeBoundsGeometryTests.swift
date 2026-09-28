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
}

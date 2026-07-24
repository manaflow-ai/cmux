import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct PaneMapTerminalPreviewLayoutTests {
    @Test func overflowingPreviewUsesInsetLatestRowsAndBottomAttachment() {
        let layout = PaneMapTerminalCanvasLayout(
            size: CGSize(width: 112, height: 50),
            columns: 10,
            rowCount: 20,
            inset: 6
        )

        #expect(layout.contentRect == CGRect(x: 6, y: 6, width: 100, height: 38))
        #expect(layout.visibleRowRange == 18..<20)
        #expect(layout.drawOrigin.x == 6)
        #expect(layout.drawOrigin.y >= 6)
        #expect(abs(layout.lastRowMaxY - layout.contentRect.maxY) < 0.001)
    }

    @Test func shortPreviewKeepsItsFirstRowTopAttachedInsideTheInset() {
        let layout = PaneMapTerminalCanvasLayout(
            size: CGSize(width: 112, height: 80),
            columns: 10,
            rowCount: 2,
            inset: 6
        )

        #expect(layout.visibleRowRange == 0..<2)
        #expect(layout.drawOrigin == CGPoint(x: 6, y: 6))
    }
}

@Suite struct PaneMapTabStripMetricsTests {
    @Test func stripHugsTabsUntilItsMaximumWidth() {
        #expect(PaneMapTabStripMetrics.width(tabCount: 2) == 64)
        #expect(PaneMapTabStripMetrics.width(tabCount: 3) == 94)
        #expect(PaneMapTabStripMetrics.width(tabCount: 4) == 124)
        #expect(PaneMapTabStripMetrics.width(tabCount: 5) == 132)
        #expect(PaneMapTabStripMetrics.width(tabCount: 20) == 132)
    }
}

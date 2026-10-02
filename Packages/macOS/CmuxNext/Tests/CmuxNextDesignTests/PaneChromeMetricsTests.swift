import CoreGraphics
import Testing
@testable import CmuxNextDesign

/// One set of numbers for the pane chrome (dogfood 2026-10-01): equal gaps
/// above and below the tab pill on every pixel grid, the first pill on the
/// border's line, the first terminal cell 4 pt inside the border.
@Suite struct PaneChromeMetricsTests {
    private func gaps(_ m: PaneChromeMetrics, scale: CGFloat) -> (above: CGFloat, below: CGFloat) {
        let top = m.pillTop(scale: scale)
        return (m.panePadding.isZero ? top : PaneChromeMetrics.snap(m.panePadding, scale) + top,
                m.resolvedStripHeight(scale: scale) - top - m.tabHeight)
    }

    @Test(arguments: [CGFloat(1), 2, 3])
    func theDensityDefaultsSplitEvenlyAndKeepTheStripToken(scale: CGFloat) {
        let compact = PaneChromeMetrics(stripHeight: 28, tabHeight: 24, panePadding: 2)
        #expect(compact.pillTop(scale: scale) == 1)
        #expect(compact.tabGap(scale: scale) == 3)
        #expect(compact.resolvedStripHeight(scale: scale) == 28)
        let comfortable = PaneChromeMetrics(stripHeight: 36, tabHeight: 30, panePadding: 4)
        #expect(comfortable.pillTop(scale: scale) == 1)
        #expect(comfortable.tabGap(scale: scale) == 5)
        #expect(comfortable.resolvedStripHeight(scale: scale) == 36)
    }

    /// Any padding, any scale: above and below are equal and on the grid.
    @Test(arguments: [CGFloat(1), 2])
    func gapsAreEqualForEveryPadding(scale: CGFloat) {
        for padding in stride(from: CGFloat(0), through: 8, by: 0.5) {
            let m = PaneChromeMetrics(stripHeight: 28, tabHeight: 24, panePadding: padding)
            let (above, below) = gaps(m, scale: scale)
            #expect(above == below, "padding \(padding) at \(scale)x: \(above) vs \(below)")
            #expect((above * scale).rounded() == above * scale)
            #expect(m.resolvedStripHeight(scale: scale) <= max(28, 24 + 2 * PaneChromeMetrics.snap(padding, scale)))
        }
    }

    @Test func pillAndTerminalSitOnTheBorderLine() {
        #expect(PaneChromeMetrics.pillLeading == 0)
        #expect(Metrics.paneChromeInset == 0)
        #expect(PaneChromeMetrics.terminalTextInset == 4)
    }
}

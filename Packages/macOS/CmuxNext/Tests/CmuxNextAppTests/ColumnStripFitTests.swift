import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// Columns fill the visible strip exactly (Lawrence 2026-10-26: "panes/columns should snap to
/// 100% of the visible area; otherwise there is a slight horizontal scroll"). Each column width
/// is rounded to a device pixel on its own, and the rounding can add up: with equal columns
/// (`layout.newColumnWidth` fit visible columns) the strip ends up half a point to a point and a
/// half wider than the viewport, which gives a few points of horizontal scroll that no column
/// asks for. A strip whose columns fit must have no overflow to scroll.
@Suite struct ColumnStripFitTests {
    static let viewports: [CGFloat] = [600.5, 1000, 1200.25, 1279.75, 1437.5, 1919.75]

    /// Equal columns that share the strip (`1 / count` each) end exactly at the viewport's
    /// trailing edge, leaving no scroll.
    @Test(arguments: [1, 2, 3, 4, 5, 6], [1.0, 2.0])
    func equalColumnsFillTheViewportWithoutOverflow(count: Int, scale: CGFloat) {
        let gap: CGFloat = 8
        for viewport in Self.viewports {
            let fraction = 1.0 / Double(count)
            let result = ColumnStripGeometry.frames(
                widths: Array(repeating: fraction, count: count),
                viewport: CGSize(width: viewport, height: 800),
                gap: gap,
                scale: scale
            )
            #expect(abs(result.contentWidth - viewport) < 0.001,
                    "\(count) columns at scale \(scale) in \(viewport) pt: content \(result.contentWidth)")
            let last = result.frames.last
            #expect(abs((last?.maxX ?? 0) + gap - viewport) < 0.001,
                    "the last column ends at the trailing edge: \(String(describing: last)) in \(viewport)")
            #expect(ColumnStripGeometry.maxOffset(contentWidth: result.contentWidth, viewportWidth: viewport) < 0.001,
                    "no horizontal scroll with \(count) columns in \(viewport) pt")
        }
    }

    /// The same through the screen geometry the layout view scrolls: a screen of equal columns
    /// has no content past its viewport.
    @Test(arguments: [2, 3, 4, 5])
    func screenGeometryOfEqualColumnsHasNoOverflow(count: Int) {
        let style = LayoutStyle()
        let columns = (0..<count).map { index in
            LayoutColumn(id: ColumnID("c\(index)"), width: 1.0 / Double(count), root: .leaf(PaneID("p\(index)")))
        }
        for viewport in Self.viewports {
            let geometry = ScreenGeometry.compute(.columns(columns), viewport: CGSize(width: viewport, height: 800), style: style, scale: 2)
            #expect(abs(geometry.contentWidth - viewport) < 0.001,
                    "\(count) columns in \(viewport) pt: content \(geometry.contentWidth)")
            #expect(geometry.maxOffset < 0.001, "no horizontal scroll with \(count) columns in \(viewport) pt: \(geometry.maxOffset)")
        }
    }
}

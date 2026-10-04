import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Docked side docks leave the scrolling strip at least
/// `StickyStripGeometry.minimumStripWidth` (at most half the viewport):
/// with a 40% dock on each side of an 850 pt window the strip was 170 pt and
/// its tab titles were cut (dogfood 2026-10-03).
@Suite struct MinimumStripWidthTests {
    let style = LayoutStyle()

    private func geometry(width: CGFloat, left: StickyMode, right: StickyMode) -> ScreenGeometry {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "l", width: 0.4, root: .leaf("pl"), sticky: StickyColumn(edge: .left, mode: left)),
            LayoutColumn(id: "c", width: 0.5, root: .leaf("pc")),
            LayoutColumn(id: "r", width: 0.4, root: .leaf("pr"), sticky: StickyColumn(edge: .right, mode: right)),
        ])
        return ScreenGeometry.compute(layout, viewport: CGSize(width: width, height: 600), style: style, scale: 2)
    }

    @Test func twoDockedSideDocksShrinkToKeepTheStrip() {
        let g = geometry(width: 850, left: .docked, right: .docked)
        #expect(g.stripWidth >= StickyStripGeometry.minimumStripWidth - 1)
        // Both docks shrink by the same factor.
        let widths = g.sticky.map(\.frame.width).sorted()
        #expect(widths.count == 2 && abs(widths[0] - widths[1]) <= 1)
    }

    @Test func aWideWindowKeepsTheDockWidths() {
        // Two 40% docks of a 3000 pt window leave about 600 pt: above the minimum.
        let g = geometry(width: 3000, left: .docked, right: .docked)
        #expect(g.stripWidth > 550)
    }

    @Test func aNarrowWindowKeepsHalfForTheStrip() {
        let g = geometry(width: 600, left: .docked, right: .docked)
        #expect(g.stripWidth >= 299)
    }

    @Test func floatingDocksDoNotShrink() {
        let docked = geometry(width: 850, left: .docked, right: .docked)
        let floating = geometry(width: 850, left: .overlay, right: .overlay)
        #expect(floating.stripWidth == 850)
        #expect(floating.sticky.map(\.frame.width).max()! > docked.sticky.map(\.frame.width).max()!)
    }
}

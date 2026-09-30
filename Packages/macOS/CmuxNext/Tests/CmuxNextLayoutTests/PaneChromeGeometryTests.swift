import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Pane padding, corner radius and border in the pure geometry.
@Suite struct PaneChromeGeometryTests {
    private func style(padding: CGFloat, radius: CGFloat = 6, border: Bool = true, gap: CGFloat = 6) -> LayoutStyle {
        var style = LayoutStyle()
        style.columnGap = gap
        style.dividerThickness = 1
        style.dividerHitThickness = 7
        style.paneChromeHeight = 28
        style.minimumPaneContentSize = CGSize(width: 200, height: 64)
        style.panePadding = padding
        style.paneCornerRadius = radius
        style.showsPaneBorder = border
        return style
    }

    private let viewport = CGSize(width: 1000, height: 600)
    private let twoByTwo = SplitNode.split(
        "root", axis: .horizontal, ratio: 0.5,
        a: .split("left", axis: .vertical, ratio: 0.5, a: .leaf("tl"), b: .leaf("bl")),
        b: .split("right", axis: .vertical, ratio: 0.5, a: .leaf("tr"), b: .leaf("br"))
    )

    @Test func contentRectInsetsTheCellByThePadding() {
        let cell = CGRect(x: 10, y: 20, width: 300, height: 200)
        #expect(PaneChromeGeometry.contentRect(forCell: cell, style: style(padding: 4)) == CGRect(x: 14, y: 24, width: 292, height: 192))
        #expect(PaneChromeGeometry.contentRect(forCell: cell, style: style(padding: 0)) == cell)
        // A cell thinner than twice the padding collapses, never inverts.
        let thin = PaneChromeGeometry.contentRect(forCell: CGRect(x: 0, y: 0, width: 6, height: 100), style: style(padding: 4))
        #expect(thin.width == 0 && thin.minX == 3 && thin.height == 92)
    }

    @Test func cornerRadiusFitsTheRect() {
        #expect(PaneChromeGeometry.cornerRadius(for: CGRect(x: 0, y: 0, width: 100, height: 100), style: style(padding: 2, radius: 8)) == 8)
        #expect(PaneChromeGeometry.cornerRadius(for: CGRect(x: 0, y: 0, width: 100, height: 10), style: style(padding: 2, radius: 8)) == 5)
        #expect(PaneChromeGeometry.cornerRadius(for: CGRect(x: 0, y: 0, width: 100, height: 100), style: style(padding: 0, radius: 0)) == 0)
    }

    @Test func hairlineIsOneDevicePixel() {
        #expect(PaneChromeGeometry.hairlineWidth(scale: 2) == 0.5)
        #expect(PaneChromeGeometry.hairlineWidth(scale: 1) == 1)
        #expect(PaneChromeGeometry.hairlineWidth(scale: 3) == 1.0 / 3)
    }

    @Test func minimumPaneSizeIncludesPaddingOnBothSides() {
        let padded = style(padding: 4)
        #expect(padded.minimumPaneSize == CGSize(width: 208, height: 28 + 64 + 8))
        #expect(style(padding: 0).minimumPaneSize == CGSize(width: 200, height: 92))
    }

    @Test func paddedPanesKeepTheirMinimumContentWhenSqueezed() {
        let padded = style(padding: 4)
        // Room for exactly two minimum panes across and two down, plus dividers.
        let tight = CGSize(width: 208 * 2 + 1, height: 100 * 2 + 1)
        let geometry = ScreenGeometry.compute(.splits(twoByTwo), viewport: tight, style: padded)
        for (_, cell) in geometry.panes {
            let content = PaneChromeGeometry.contentRect(forCell: cell, style: padded)
            #expect(content.width >= 200 - 0.5)
            #expect(content.height >= 28 + 64 - 0.5)
        }
        // One point narrower: splitting any pane sideways is refused.
        let room = SplitRoom.placement(splitting: "tl", axis: .horizontal, in: .splits(twoByTwo), viewport: tight, style: padded)
        #expect(room == .refused(.notEnoughRoom))
    }

    @Test func dividerHitAreaCoversTheWholeGapBetweenPaddedPanes() {
        let padded = style(padding: 6)
        let geometry = ScreenGeometry.compute(.splits(twoByTwo), viewport: viewport, style: padded)
        let root = try! #require(geometry.dividers.first { $0.id == "root" })
        let left = PaneChromeGeometry.contentRect(forCell: geometry.panes["tl"]!, style: padded)
        let right = PaneChromeGeometry.contentRect(forCell: geometry.panes["tr"]!, style: padded)
        // The gap between the two content rects lies inside the hit area.
        #expect(root.hitFrame.minX <= left.maxX)
        #expect(root.hitFrame.maxX >= right.minX)
        #expect(root.hitFrame.width == 13)
        // Small padding keeps the default hit width.
        let small = ScreenGeometry.compute(.splits(twoByTwo), viewport: viewport, style: style(padding: 2))
        #expect(small.dividers.first { $0.id == "root" }?.hitFrame.width == 7)
    }

    @Test func columnGapAndPaddingDoNotDoubleUp() {
        let columns = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("a")),
            LayoutColumn(id: "c2", width: 0.5, root: .leaf("b")),
        ])
        for (padding, gap) in [(CGFloat(2), CGFloat(6)), (4, 6), (0, 6), (6, 4)] {
            let s = style(padding: padding, gap: gap)
            let geometry = ScreenGeometry.compute(columns, viewport: viewport, style: s)
            let a = PaneChromeGeometry.contentRect(forCell: geometry.panes["a"]!, style: s)
            let b = PaneChromeGeometry.contentRect(forCell: geometry.panes["b"]!, style: s)
            #expect(b.minX - a.maxX == max(gap, padding * 2), "padding \(padding) gap \(gap)")
            // Leading edge: the strip gap plus the pane's own padding.
            #expect(a.minX == s.stripGap + padding, "padding \(padding) gap \(gap)")
            // The column edge's drag area spans the visible gap.
            let edge = try! #require(geometry.columnEdges.first { $0.column == "c1" })
            #expect(edge.hitFrame.minX <= a.maxX && edge.hitFrame.maxX >= b.minX)
        }
    }

    @Test func noPaddingNoBorderIsTodaysEdgeToEdgeLayout() {
        let plain = style(padding: 0, radius: 0, border: false)
        #expect(!plain.hasPaneChrome)
        #expect(plain.showsDividerLine)
        #expect(plain.stripGap == plain.columnGap)
        #expect(plain.effectiveDividerHitThickness == plain.dividerHitThickness)
        #expect(plain.columnEdgeHitThickness == max(plain.columnGap, plain.dividerHitThickness))
        #expect(plain.minimumPaneSize == CGSize(width: 200, height: 92))
        let geometry = ScreenGeometry.compute(.splits(twoByTwo), viewport: viewport, style: plain)
        for (_, cell) in geometry.panes {
            #expect(PaneChromeGeometry.contentRect(forCell: cell, style: plain) == cell)
        }
        // Panes and the divider tile the viewport with no gap.
        #expect(geometry.panes["tl"]!.minX == 0 && geometry.panes["tr"]!.maxX == viewport.width)
        #expect(geometry.panes["tl"]!.maxX + 1 == geometry.panes["tr"]!.minX)
    }

    @Test func borderHidesTheIdleDividerLine() {
        #expect(!style(padding: 2, border: true).showsDividerLine)
        #expect(style(padding: 2, border: false).showsDividerLine)
    }

    @Test func paneDropHighlightTracesTheContentRect() {
        let padded = style(padding: 4)
        let geometry = ScreenGeometry.compute(.splits(twoByTwo), viewport: viewport, style: padded)
        let content = PaneChromeGeometry.contentRect(forCell: geometry.panes["br"]!, style: padded)
        #expect(DropZoneGeometry.highlightRect(for: .pane("br", .center), geometry: geometry, style: padded) == content)
        let right = DropZoneGeometry.highlightRect(for: .pane("br", .right), geometry: geometry, style: padded)
        #expect(right == CGRect(x: content.midX, y: content.minY, width: content.width / 2, height: content.height))
        // A point in the padding still targets the pane.
        let cell = geometry.panes["br"]!
        let target = DropZoneGeometry.target(at: CGPoint(x: cell.midX, y: cell.maxY - 1), screen: "s", geometry: geometry, style: padded)
        #expect(target == .pane("br", .bottom))
    }
}

import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Edge dock drop targets (layout-model.md, DD1): a band at the top or
/// bottom edge opens a dock while that edge has none. The band ignores the
/// strip's scroll offset, because a dock spans the screen.
@Suite struct DockDropTargetTests {
    let viewport = CGSize(width: 1000, height: 600)
    let style = LayoutStyle()

    private func geometry(dock: StickyColumn? = nil) -> ScreenGeometry {
        var columns = [0.5, 0.5].enumerated().map { index, width in
            LayoutColumn(id: ColumnID("c\(index)"), width: width, root: .leaf(PaneID("p\(index)")))
        }
        if let dock {
            columns.append(LayoutColumn(id: ColumnID("d"), width: 0.3, root: .leaf(PaneID("pd")), sticky: dock))
        }
        return ScreenGeometry.compute(.columns(columns), viewport: viewport, style: style, scale: 2)
    }

    private func dock(_ g: ScreenGeometry, y: CGFloat) -> DropTarget? {
        DropZoneGeometry.dockTarget(atView: CGPoint(x: 500, y: y), screen: "s", geometry: g, style: style)
    }

    @Test func theEdgeBandsOpenADock() {
        let g = geometry()
        #expect(dock(g, y: 0) == .newDock(screen: "s", edge: .top))
        #expect(dock(g, y: style.dockDropBand) == .newDock(screen: "s", edge: .top))
        #expect(dock(g, y: 600) == .newDock(screen: "s", edge: .bottom))
        #expect(dock(g, y: 300) == nil)
    }

    @Test func anEdgeThatHasADockOpensNoSecondOne() {
        let g = geometry(dock: StickyColumn(edge: .top, mode: .docked))
        #expect(dock(g, y: 0) == nil)
        #expect(dock(g, y: 600) == .newDock(screen: "s", edge: .bottom))
    }

    @Test func theBandIsAtMostAQuarterOfAShortScreen() {
        let short = ScreenGeometry.compute(.columns([LayoutColumn(id: ColumnID("c0"), width: 1, root: .leaf(PaneID("p0")))]),
                                           viewport: CGSize(width: 400, height: 40), style: style, scale: 2)
        #expect(DropZoneGeometry.dockTarget(atView: CGPoint(x: 10, y: 15), screen: "s", geometry: short, style: style) == nil)
        #expect(DropZoneGeometry.dockTarget(atView: CGPoint(x: 10, y: 9), screen: "s", geometry: short, style: style)
                == .newDock(screen: "s", edge: .top))
    }

    @Test func thePreviewSpansTheScreenAndIgnoresTheScroll() {
        let g = geometry()
        let top = DropZoneGeometry.highlightRectInView(for: .newDock(screen: "s", edge: .top), offset: 250, geometry: g, style: style)
        #expect(top == CGRect(x: style.stripGap, y: 0, width: 1000 - style.stripGap * 2, height: 180))
        let bottom = DropZoneGeometry.regionRectInView(for: .newDock(screen: "s", edge: .bottom), offset: 250, geometry: g, style: style)
        #expect(bottom?.maxY == 600)
        #expect(bottom?.height == 180)
    }
}

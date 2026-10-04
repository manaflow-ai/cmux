import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Drop target resolution with a docked column (dock-column.md, D1 to D3):
/// docked panes sit above the strip and take drops; what a docked column
/// covers never drops into the strip below it.
@Suite struct DockedColumnDropTargetTests {
    let viewport = CGSize(width: 1000, height: 600)
    let style = LayoutStyle()

    private func geometry(_ dock: DockColumn, widths: [Double], dockIndex: Int) -> ScreenGeometry {
        let layout = ScreenLayout.columns(widths.enumerated().map { index, width in
            LayoutColumn(id: ColumnID("c\(index)"), width: width, root: .leaf(PaneID("p\(index)")),
                         dock: index == dockIndex ? dock : nil)
        })
        return ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: 2)
    }

    private func target(_ g: ScreenGeometry, _ x: CGFloat, _ y: CGFloat = 300, offset: CGFloat = 0) -> DropTarget? {
        DropZoneGeometry.target(atView: CGPoint(x: x, y: y), offset: offset, screen: "s", geometry: g, style: style)
    }

    @Test func theDockPaneTakesTheDropAboveTheStrip() {
        let g = geometry(DockColumn(edge: .right, mode: .overlay), widths: [0.5, 0.5, 0.3], dockIndex: 2)
        // x 848 is in the overlay column and over strip column c1 (503...994).
        #expect(target(g, 848) == .pane("p2", .center))
        #expect(target(g, 710) == .pane("p2", .left))
    }

    @Test func theGlassRimTakesNoDrop() {
        let g = geometry(DockColumn(edge: .right, mode: .overlay), widths: [0.5, 0.5, 0.3], dockIndex: 2)
        #expect(target(g, 700) == nil)
        #expect(target(g, 996) == nil)
        // The band between the rim and the window edge is covered too.
        #expect(target(g, 999) == nil)
    }

    @Test func theStripResolvesInItsOwnSpaceBesideADockedColumn() {
        let g = geometry(DockColumn(edge: .left, mode: .docked), widths: [0.3, 0.5, 0.5], dockIndex: 0)
        // Strip origin 298: view x 450 is strip x 152, inside c1 (6...348).
        #expect(target(g, 450) == .pane("p1", .center))
        // The gap between c1 and c2 is at strip x 351, view x 649.
        #expect(target(g, 649) == .newColumn(screen: "s", after: "c1"))
        // The docked band left of the strip is covered: no drop.
        #expect(target(g, 3) == nil)
        #expect(target(g, 200) == .pane("p0", .center))
    }

    @Test func aScrolledStripStillResolvesUnderTheOffset() {
        let g = geometry(DockColumn(edge: .right, mode: .overlay), widths: [0.5, 0.5, 0.3], dockIndex: 2)
        // Scrolled to the end (298): c1 shows at 205...696.
        #expect(target(g, 450, offset: 298) == .pane("p1", .center))
        #expect(target(g, 100, offset: 298) == .pane("p0", .right))
    }

    @Test func highlightsAreInViewCoordinates() {
        let g = geometry(DockColumn(edge: .left, mode: .docked), widths: [0.3, 0.5, 0.5], dockIndex: 0)
        let strip = DropZoneGeometry.highlightRectInView(for: .pane("p1", .center), offset: 0, geometry: g, style: style)
        #expect(strip == CGRect(x: 304, y: 0, width: 342, height: 600))
        let dock = DropZoneGeometry.highlightRectInView(for: .pane("p0", .center), offset: 120, geometry: g, style: style)
        #expect(dock == CGRect(x: 6, y: 0, width: 292, height: 600))
    }
}

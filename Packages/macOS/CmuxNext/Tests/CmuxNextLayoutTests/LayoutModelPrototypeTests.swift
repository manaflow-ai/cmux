import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// The DEV layout model prototypes (plans/cmux-next/layout-model.md,
/// "Prototypes"): off keeps the real layout, the frame draws the right sticky
/// column as a top or bottom dock between the side docks (F1), the grid lines
/// panes up in rows shared across columns and leaves holes.
@Suite struct LayoutModelPrototypeTests {
    let viewport = CGSize(width: 1000, height: 600)

    private func style(_ model: LayoutPrototypeModel, edge: LayoutPrototypeDockEdge = .bottom,
                       orientation: LayoutPrototypeOrientation = .columnMajor) -> LayoutStyle {
        var style = LayoutStyle()
        style.prototype = LayoutPrototypeSettings(model: model, dockEdge: edge, orientation: orientation)
        return style
    }

    /// Left sticky c0, strip c1 and c2 (c2 split down into p2 and p3), right sticky c3 (0.3).
    private var layout: ScreenLayout {
        .columns([
            LayoutColumn(id: "c0", width: 0.25, root: .leaf("p0"), sticky: StickyColumn(edge: .left, mode: .docked)),
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.5, root: .split("s2", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))),
            LayoutColumn(id: "c3", width: 0.3, root: .leaf("p4"), sticky: StickyColumn(edge: .right, mode: .docked)),
        ])
    }

    private func geometry(_ style: LayoutStyle) -> ScreenGeometry {
        ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: 2)
    }

    @Test func offIsTheRealLayout() {
        #expect(geometry(style(.off)) == geometry(LayoutStyle()))
    }

    @Test func frameDocksTheRightColumnAtTheBottomBetweenTheSideDocks() {
        let g = geometry(style(.frameDocks))
        let left = try! #require(g.panes["p0"])
        let band = try! #require(g.panes["p4"])
        // The left dock keeps the full height: corners belong to the side docks.
        #expect(left.minY == 0 && left.height == 600)
        // 600 * 0.3 = 180 high, from the left dock's inner edge plus a gap to one gap from the right edge.
        #expect(band.minY == 420 && band.height == 180)
        #expect(band.minX == left.maxX + 6)
        #expect(band.maxX == 994)
        #expect(g.fixedPanes.isSuperset(of: ["p0", "p4"]))
        // Strip panes end above the band and its gap.
        for pane: PaneID in ["p1", "p2", "p3"] {
            #expect((g.panes[pane]?.maxY ?? .infinity) <= 414)
        }
        #expect(g.columnOrder == ["c1", "c2"])
    }

    @Test func rowMajorFrameRunsTheBandFullWidthAndKeepsTheLeftDockBetween() {
        let g = geometry(style(.frameDocks, orientation: .rowMajor))
        let band = try! #require(g.panes["p4"])
        #expect(band.minX == 6 && band.maxX == 994)
        // The left dock stops above the bottom band and its gap.
        #expect((g.panes["p0"]?.maxY ?? .infinity) <= 414)
    }

    @Test func frameDocksAtTheTopShiftTheStripDown() {
        let g = geometry(style(.frameDocks, edge: .top))
        #expect(g.panes["p4"]?.minY == 0)
        #expect(g.panes["p0"]?.minY == 0 && g.panes["p0"]?.height == 600)
        for pane: PaneID in ["p1", "p2", "p3"] {
            #expect((g.panes[pane]?.minY ?? 0) >= 186)
        }
    }

    @Test func frameWithoutStickyColumnsDocksThePlainColumns() {
        let plain: ScreenLayout = .columns(["a", "b", "c"].map { LayoutColumn(id: ColumnID($0), width: 0.3, root: .leaf(PaneID("p\($0)"))) })
        let g = ScreenGeometry.compute(plain, viewport: viewport, style: style(.frameDocks))
        // The last column becomes the bottom band, the first the full-height left dock.
        #expect(g.panes["pc"]?.maxY == 600 && g.panes["pc"]?.minY == 420)
        #expect(g.panes["pa"]?.minY == 0 && g.panes["pa"]?.height == 600)
        #expect(g.columnOrder == ["b"])
    }

    @Test func frameWithOneColumnKeepsTheRealLayout() {
        let one: ScreenLayout = .columns([LayoutColumn(id: "a", width: 1, root: .leaf("x"))])
        #expect(ScreenGeometry.compute(one, viewport: viewport, style: style(.frameDocks)) == ScreenGeometry.compute(one, viewport: viewport, style: LayoutStyle()))
    }

    @Test func gridAlignsRowsAcrossColumnsAndLeavesHoles() {
        let g = geometry(style(.grid))
        // Two grid rows of (600 - 6) / 2 = 297.
        #expect(g.panes["p1"] == CGRect(x: g.columns["c1"]!.minX, y: 0, width: g.columns["c1"]!.width, height: 297))
        #expect(g.panes["p2"]?.minY == 0 && g.panes["p3"]?.minY == 303)
        // Column c1 has no second cell: a hole under p1, and no in-column divider remains.
        #expect(!g.panes.values.contains { $0.minY == 303 && $0.minX == g.columns["c1"]!.minX })
        #expect(!g.dividers.contains { $0.id == "s2" })
    }
}

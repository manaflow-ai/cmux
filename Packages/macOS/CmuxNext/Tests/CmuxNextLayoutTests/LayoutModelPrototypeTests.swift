import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// The DEV layout model prototypes (plans/cmux-next/layout-model.md,
/// "Prototypes"): off keeps the real layout, the frame draws the right sticky
/// column as a top or bottom dock between the side docks (F1), the grid lines
/// panes up in rows shared across columns and leaves holes.
@Suite struct LayoutModelPrototypeTests {
    let viewport = CGSize(width: 1000, height: 600)

    private func style(_ model: LayoutPrototypeModel, edge: LayoutPrototypeDockEdge = .bottom) -> LayoutStyle {
        var style = LayoutStyle()
        style.prototype = LayoutPrototypeSettings(model: model, dockEdge: edge)
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

    @Test func frameDocksAtTheTopShiftTheStripDown() {
        let g = geometry(style(.frameDocks, edge: .top))
        #expect(g.panes["p4"]?.minY == 0)
        #expect(g.panes["p0"]?.minY == 0 && g.panes["p0"]?.height == 600)
        for pane: PaneID in ["p1", "p2", "p3"] {
            #expect((g.panes[pane]?.minY ?? 0) >= 186)
        }
    }

    @Test func frameWithoutARightStickyColumnKeepsTheRealLayout() {
        let plain: ScreenLayout = .columns([LayoutColumn(id: "a", width: 0.5, root: .leaf("x")), LayoutColumn(id: "b", width: 0.5, root: .leaf("y"))])
        #expect(ScreenGeometry.compute(plain, viewport: viewport, style: style(.frameDocks)) == ScreenGeometry.compute(plain, viewport: viewport, style: LayoutStyle()))
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

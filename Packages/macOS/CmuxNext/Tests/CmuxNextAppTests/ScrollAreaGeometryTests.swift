import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// Horizontal scroll areas (plans/cmux-next/scroll-areas-DESIGN.md, design A "overflow
/// splits"): with `layout.scrollAreas` on, a split tree that needs more width than its frame
/// scrolls inside that frame instead of squashing its panes, columns keep their width, focus
/// reveals a pane inside its area, and Cmd-Opt-arrows step through an area's panes and leave it
/// at its ends. Off, the geometry is today's.
@Suite struct ScrollAreaGeometryTests {
    static let viewport = CGSize(width: 1200, height: 800)

    static func style(scrollAreas: Bool) -> LayoutStyle {
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 300, height: 64)
        style.scrollAreasEnabled = scrollAreas
        return style
    }

    /// p1 | p2 | p3: a horizontal chain of three panes.
    static let chain: SplitNode = .split(SplitID("s1"), axis: .horizontal, ratio: 1.0 / 3,
                                         a: .leaf(PaneID("p1")),
                                         b: .split(SplitID("s2"), axis: .horizontal, ratio: 0.5, a: .leaf(PaneID("p2")), b: .leaf(PaneID("p3"))))

    /// A strip column with one pane and a right docked column holding the chain.
    static var dockLayout: ScreenLayout {
        .columns([
            LayoutColumn(id: ColumnID("c1"), width: 0.6, root: .leaf(PaneID("p0"))),
            LayoutColumn(id: ColumnID("dock"), width: 0.3, root: chain, dock: DockColumn(edge: .right, mode: .docked)),
        ])
    }

    /// Two half columns: the chain, then one pane.
    static var stripLayout: ScreenLayout {
        .columns([
            LayoutColumn(id: ColumnID("c1"), width: 0.5, root: chain),
            LayoutColumn(id: ColumnID("c2"), width: 0.5, root: .leaf(PaneID("q"))),
        ])
    }

    @Test func offKeepsTodaysGeometry() {
        for layout in [Self.dockLayout, Self.stripLayout, .splits(Self.chain)] {
            let geometry = ScreenGeometry.compute(layout, viewport: CGSize(width: 700, height: 800), style: Self.style(scrollAreas: false))
            #expect(geometry.scrollAreas.isEmpty, "off: no scroll areas")
        }
    }

    @Test func aDockedColumnScrollsItsSplitsInsteadOfSquashingThem() throws {
        let style = Self.style(scrollAreas: true)
        let geometry = ScreenGeometry.compute(Self.dockLayout, viewport: Self.viewport, style: style)
        let dock = try #require(geometry.columns[ColumnID("dock")])
        let area = try #require(geometry.scrollAreas[SplitID("s1")], "the dock's chain is a scroll area")
        #expect(area.window == dock, "the area shows through the docked column's frame: \(area.window) vs \(dock)")
        #expect(area.contentWidth > dock.width + 1, "the chain is wider than the dock: \(area.contentWidth)")
        #expect(area.panes == [PaneID("p1"), PaneID("p2"), PaneID("p3")])
        #expect(area.cells.count == 3)
        for pane in area.panes {
            let frame = try #require(geometry.panes[pane])
            #expect(frame.width >= style.minimumPaneSize.width - 0.5, "\(pane) keeps the minimum width: \(frame.width)")
            #expect(geometry.scrollAreaOfPane[pane] == SplitID("s1"))
        }
        #expect(geometry.scrollAreaOfSplit[SplitID("s2")] == SplitID("s1"))
    }

    @Test func aStripColumnKeepsItsWidthAndScrollsInside() throws {
        let on = ScreenGeometry.compute(Self.stripLayout, viewport: Self.viewport, style: Self.style(scrollAreas: true))
        let off = ScreenGeometry.compute(Self.stripLayout, viewport: Self.viewport, style: Self.style(scrollAreas: false))
        let column = try #require(on.columns[ColumnID("c1")]), neighbor = try #require(on.columns[ColumnID("c2")])
        #expect(abs(column.width - neighbor.width) < 1, "on: two half columns stay equal: \(column.width) vs \(neighbor.width)")
        #expect((off.columns[ColumnID("c1")]?.width ?? 0) > column.width + 1, "off: the column widens to fit its splits (today)")
        let area = try #require(on.scrollAreas[SplitID("s1")])
        #expect(area.window == column)
    }

    @Test func aSplitScreenThatCannotFitScrolls() throws {
        let geometry = ScreenGeometry.compute(.splits(Self.chain), viewport: CGSize(width: 700, height: 800), style: Self.style(scrollAreas: true))
        let area = try #require(geometry.scrollAreas[SplitID("s1")])
        #expect(area.window == CGRect(x: 0, y: 0, width: 700, height: 800))
        #expect(area.contentWidth > 700)
        // Fits: no area.
        let wide = ScreenGeometry.compute(.splits(Self.chain), viewport: CGSize(width: 1400, height: 800), style: Self.style(scrollAreas: true))
        #expect(wide.scrollAreas.isEmpty, "a split that fits never scrolls")
    }

    @Test func directionalFocusStepsThroughTheAreaThenLeavesIt() throws {
        let geometry = ScreenGeometry.compute(Self.stripLayout, viewport: Self.viewport, style: Self.style(scrollAreas: true))
        var frames: [PaneID: CGRect] = [:]
        for pane in geometry.panes.keys { frames[pane] = geometry.navigationRect(of: pane) }
        let column = try #require(geometry.columns[ColumnID("c1")])
        for pane in ["p1", "p2", "p3"] {
            let rect = try #require(frames[PaneID(pane)])
            #expect(rect.minX >= column.minX - 0.5 && rect.maxX <= column.maxX + 0.5, "\(pane) navigates inside its column: \(rect)")
        }
        func right(_ pane: String) -> PaneID? { FocusNavigation.neighbor(of: PaneID(pane), direction: .right, frames: frames) }
        func left(_ pane: String) -> PaneID? { FocusNavigation.neighbor(of: PaneID(pane), direction: .left, frames: frames) }
        #expect(right("p1") == PaneID("p2"))
        #expect(right("p2") == PaneID("p3"))
        #expect(right("p3") == PaneID("q"), "right from the area's last pane leaves it")
        #expect(left("q") == PaneID("p3"), "left into the area lands on its nearest pane")
        #expect(left("p2") == PaneID("p1"))
    }

    @Test func focusRevealsAPaneScrolledOutOfItsArea() throws {
        let geometry = ScreenGeometry.compute(Self.dockLayout, viewport: Self.viewport, style: Self.style(scrollAreas: true))
        let area = try #require(geometry.scrollAreas[SplitID("s1")])
        var scroll = ScrollAreaScroll()
        _ = scroll.state.reduce(.sync(scroll.strip(area), focused: PaneID("p3"), source: .keyboard, animated: false))
        let offset = scroll.state.spring.target
        let pane = try #require(geometry.panes[PaneID("p3")]).offsetBy(dx: -area.window.minX, dy: 0)
        #expect(pane.minX >= offset - 0.5 && pane.maxX <= offset + area.window.width + 0.5,
                "p3 (\(pane.minX)...\(pane.maxX)) shows in the window at offset \(offset)")
        #expect(offset <= area.maxOffset + 0.5)
        // Back to the first pane: the area scrolls back.
        _ = scroll.state.reduce(.sync(scroll.strip(area), focused: PaneID("p1"), source: .keyboard, animated: false))
        #expect(scroll.state.spring.target < 0.5)
    }

    /// A docked column or a split screen refuses a side-by-side split with no room today; with
    /// scroll areas on, the split happens and the panes scroll. Strip columns keep opening a
    /// new column (column-scroll.md W5).
    @Test func aSplitWithNoRoomScrollsInADockAndOnASplitScreen() {
        let narrow = CGSize(width: 700, height: 800)
        for (on, expected) in [(false, SplitPlacement.refused(.notEnoughRoom)), (true, SplitPlacement.split)] {
            let style = Self.style(scrollAreas: on)
            #expect(SplitRoom.placement(splitting: PaneID("p3"), axis: .horizontal, in: Self.dockLayout, viewport: Self.viewport, style: style) == expected,
                    "dock, scroll areas \(on)")
            #expect(SplitRoom.placement(splitting: PaneID("p3"), axis: .horizontal, in: .splits(Self.chain), viewport: narrow, style: style) == expected,
                    "split screen, scroll areas \(on)")
            #expect(SplitRoom.placement(splitting: PaneID("p3"), axis: .horizontal, in: Self.stripLayout, viewport: narrow, style: style) == .newColumn,
                    "strip column, scroll areas \(on)")
        }
    }
}

import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Where a new pane goes: New Pane (Auto Layout) and
/// `layout.newPanePlacement: split` split the largest scrolling pane along
/// its longer side (Zellij), never a docked column; `tab` placement opens a
/// tab in the focused pane; browsers tile only when asked.
@Suite struct PanePlacementTests {
    private let docked = PaneID("docked")

    /// A docked column on `edge` (none when nil) plus scrolling columns of the given panes.
    private func layout(dockEdge: DockEdge? = .left, scrolling: [[String]]) -> ScreenLayout {
        var columns = scrolling.enumerated().map { index, panes in
            LayoutColumn(id: ColumnID("c\(index)"), width: 0.5, root: tree(panes))
        }
        guard let dockEdge else { return .columns(columns) }
        let dock = LayoutColumn(id: ColumnID("dock"), width: 0.4, root: .leaf(docked),
                                dock: DockColumn(edge: dockEdge, mode: .docked))
        if dockEdge == .right { columns.append(dock) } else { columns.insert(dock, at: 0) }
        return .columns(columns)
    }

    private func tree(_ panes: [String]) -> SplitNode {
        guard let first = panes.first else { return .leaf(PaneID("empty")) }
        return panes.dropFirst().reduce(SplitNode.leaf(PaneID(first))) { node, pane in
            .split(SplitID("s-\(pane)"), axis: .vertical, ratio: 0.5, a: node, b: .leaf(PaneID(pane)))
        }
    }

    private func plan(_ layout: ScreenLayout, focused: PaneID, recent: [PaneID] = [], frames: [PaneID: CGRect] = [:],
                      placement: NewPanePlacement = .tab, tiles: Bool = true) -> PanePlacement.Plan {
        PanePlacement().plan(layout: layout, focused: focused, recent: recent, frames: frames, placement: placement, tiles: tiles)
    }

    @Test func tabPlacementOpensATabInTheFocusedPane() {
        let screen = layout(scrolling: [["t1"], ["t2"]])
        let frames = [PaneID("t1"): CGRect(x: 0, y: 0, width: 900, height: 900)]
        #expect(plan(screen, focused: PaneID("t2"), frames: frames) == .tab(in: PaneID("t2")))
        #expect(plan(screen, focused: docked, frames: frames) == .tab(in: docked))
    }

    @Test func splitPlacementSplitsTheLargestScrollingPaneAlongItsLongerSide() {
        let screen = layout(scrolling: [["t1", "t2"], ["t3"]])
        let frames: [PaneID: CGRect] = [
            docked: CGRect(x: 0, y: 0, width: 900, height: 1000),
            PaneID("t1"): CGRect(x: 900, y: 0, width: 500, height: 500),
            PaneID("t2"): CGRect(x: 900, y: 500, width: 500, height: 500),
            PaneID("t3"): CGRect(x: 1400, y: 0, width: 500, height: 1000),
        ]
        #expect(plan(screen, focused: docked, frames: frames, placement: .split) == .split(PaneID("t3"), .vertical))
        let wide = [PaneID("t3"): CGRect(x: 0, y: 0, width: 1200, height: 800), PaneID("t1"): CGRect(x: 0, y: 0, width: 10, height: 10)]
        #expect(plan(screen, focused: PaneID("t1"), frames: wide, placement: .split) == .split(PaneID("t3"), .horizontal))
    }

    @Test func browsersTileOnlyWhenAsked() {
        let screen = layout(scrolling: [["t1"]])
        let frames = [PaneID("t1"): CGRect(x: 0, y: 0, width: 800, height: 800)]
        #expect(plan(screen, focused: PaneID("t1"), frames: frames, placement: .split, tiles: false) == .tab(in: PaneID("t1")))
        #expect(plan(screen, focused: PaneID("t1"), frames: frames, placement: .split, tiles: true) == .split(PaneID("t1"), .horizontal))
    }

    @Test func autoLayoutNeverSplitsADockedColumn() {
        for edge in [DockEdge.left, .right] {
            let screen = layout(dockEdge: edge, scrolling: [["t1"]])
            let frames = [docked: CGRect(x: 0, y: 0, width: 2000, height: 2000), PaneID("t1"): CGRect(x: 0, y: 0, width: 300, height: 600)]
            let pick = PanePlacement().autoSplit(layout: screen, frames: frames, recent: [docked])
            #expect(pick?.pane == PaneID("t1"))
            #expect(pick?.axis == .vertical)
        }
    }

    @Test func noShownScrollingPaneFallsBackToTheMostRecentScrollingPane() {
        let screen = layout(scrolling: [["t1"], ["t2"]])
        let frames = [docked: CGRect(x: 0, y: 0, width: 800, height: 800)]
        #expect(PanePlacement().autoSplit(layout: screen, frames: frames, recent: [docked, PaneID("t2")])?.pane == PaneID("t2"))
        #expect(PanePlacement().autoSplit(layout: screen, frames: frames, recent: [])?.pane == PaneID("t1"))
        // Only docked columns: nothing Auto Layout may split.
        let onlyDocked = ScreenLayout.columns([LayoutColumn(id: ColumnID("dock"), width: 0.4, root: .leaf(docked),
                                                            dock: DockColumn(edge: .left, mode: .docked))])
        #expect(PanePlacement().autoSplit(layout: onlyDocked, frames: frames, recent: []) == nil)
    }

    @Test func equalAreasPreferTheMostRecentPane() {
        let screen = layout(scrolling: [["t1"], ["t2"]])
        let square = CGRect(x: 0, y: 0, width: 500, height: 500)
        let frames = [PaneID("t1"): square, PaneID("t2"): square]
        #expect(PanePlacement().autoSplit(layout: screen, frames: frames, recent: [PaneID("t2")])?.pane == PaneID("t2"))
        #expect(PanePlacement().autoSplit(layout: screen, frames: frames, recent: [])?.pane == PaneID("t1"))
    }

    @Test func aSplitsLayoutConsidersEveryPane() {
        let screen = ScreenLayout.splits(.split(SplitID("s"), axis: .horizontal, ratio: 0.5,
                                                a: .leaf(PaneID("a")), b: .leaf(PaneID("b"))))
        let frames = [PaneID("a"): CGRect(x: 0, y: 0, width: 300, height: 900), PaneID("b"): CGRect(x: 300, y: 0, width: 900, height: 900)]
        #expect(PanePlacement().autoSplit(layout: screen, frames: frames, recent: [PaneID("a")])
            == PanePlacement.Split(pane: PaneID("b"), axis: .horizontal))
    }
}

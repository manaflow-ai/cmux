@testable import CmuxNextLayout
import Testing

/// Focus Next Pane, Focus Pane 1…9, Move Tab to Next Pane and their key
/// hints count panes in the order the screen shows them. A column docked to
/// the right keeps its daemon index (columns C1, C2 docked right, C3 show as
/// C1, C3, C2), and the daemon order made Focus Next Pane from C1 jump to
/// the dock past C3, and Focus Pane 2 pick the dock (QA spree 2026-10-21).
struct PaneOrderFollowsDocksTests {
    private static let layout = ScreenLayout.columns([
        LayoutColumn(id: "c1", root: .leaf("p1")),
        LayoutColumn(id: "c2", root: .leaf("p2"), dock: DockColumn(edge: .right)),
        LayoutColumn(id: "c3", root: .split("s", axis: .vertical, ratio: 0.5, a: .leaf("p3a"), b: .leaf("p3b"))),
    ])

    @Test func aRightDockCountsLast() {
        #expect(Self.layout.visualPanes == ["p1", "p3a", "p3b", "p2"])
    }

    @Test func aLeftDockCountsFirst() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", root: .leaf("p1")),
            LayoutColumn(id: "c2", root: .leaf("p2"), dock: DockColumn(edge: .left)),
        ])
        #expect(layout.visualPanes == ["p2", "p1"])
    }

    @Test func splitsKeepTheirTreeOrder() {
        let layout = ScreenLayout.splits(.split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
        #expect(layout.visualPanes == layout.panes)
    }
}

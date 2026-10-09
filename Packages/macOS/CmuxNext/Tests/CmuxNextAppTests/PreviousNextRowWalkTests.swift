@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

/// Previous / Next over the sidebar (rapid switching, item 3): with Show
/// Tabs Under Workspaces on, each listed tab row is a step, so the keys walk
/// the expanded list one tab at a time. A workspace whose tabs are hidden
/// (the setting off, or its row collapsed) stays one step.
struct PreviousNextRowWalkTests {
    typealias Stop = PreviousNext.RowStop
    static let home = SidebarItem.topItem(LayoutItemID("home"))
    static let a = WorkspaceID("a"), b = WorkspaceID("b"), c = WorkspaceID("c")
    static let items: [SidebarItem] = [home, .workspace(a), .workspace(b), .workspace(c)]
    /// `a` lists two tabs, `b` one, `c` none (hidden or empty).
    nonisolated static func tabs(_ id: WorkspaceID) -> [TabID] {
        switch id.rawValue {
        case "a": [TabID("a1"), TabID("a2")]
        case "b": [TabID("b1")]
        default: []
        }
    }

    static let stops = PreviousNext.rowStops(items, tabs: tabs)

    @Test func eachListedTabRowIsAStep() {
        #expect(Self.stops == [
            .item(Self.home), .tab(Self.a, TabID("a1")), .tab(Self.a, TabID("a2")), .tab(Self.b, TabID("b1")),
            .item(.workspace(Self.c)),
        ])
    }

    @Test func nextAndPreviousWalkOneRowAndWrap() {
        let walk = { (from: Stop?, by: Int) in PreviousNext.stop(from: from, in: Self.stops, by: by, wraps: true) }
        #expect(walk(.tab(Self.a, TabID("a1")), 1) == .tab(Self.a, TabID("a2")))
        #expect(walk(.tab(Self.a, TabID("a2")), 1) == .tab(Self.b, TabID("b1")))
        #expect(walk(.tab(Self.b, TabID("b1")), -1) == .tab(Self.a, TabID("a2")))
        #expect(walk(.item(.workspace(Self.c)), 1) == .item(Self.home), "past the end wraps to the top")
        #expect(walk(.item(Self.home), -1) == .item(.workspace(Self.c)))
        #expect(PreviousNext.stop(from: .item(.workspace(Self.c)), in: Self.stops, by: 1, wraps: false) == nil)
    }

    /// The window's selection is a workspace; with its tabs listed, the
    /// focused tab is where the walk stands (else its first tab).
    @Test func theShownWorkspaceStandsAtItsFocusedTabRow() {
        #expect(PreviousNext.current(.workspace(Self.a), focusedTab: TabID("a2"), in: Self.stops) == .tab(Self.a, TabID("a2")))
        #expect(PreviousNext.current(.workspace(Self.a), focusedTab: TabID("elsewhere"), in: Self.stops) == .tab(Self.a, TabID("a1")))
        #expect(PreviousNext.current(.workspace(Self.c), focusedTab: nil, in: Self.stops) == .item(.workspace(Self.c)))
        #expect(PreviousNext.current(Self.home, focusedTab: nil, in: Self.stops) == .item(Self.home))
    }
}

@testable import CmuxNextTabs
import Testing

/// Next / Previous Tab (Ctrl-Tab, Cmd-Shift-] / [) and Select Tab 1…9 move
/// among the tabs the strip shows. A member of a collapsed group is not
/// drawn, so selecting it showed its content with no tab looking selected
/// and the group still collapsed (QA spree 2026-10-21, reproduced live:
/// [A, G(collapsed: g1), B, C], Ctrl-Tab from A selected g1).
@MainActor struct TabKeysSkipCollapsedGroupTests {
    /// a, then group G (g1, g2), then b, c.
    private func model(collapsed: Bool = true, selected: TabID = "a") -> TabStripModel {
        let tabs = [TabItem(id: "a", title: "a"), TabItem(id: "g1", title: "g1", groupID: "G"),
                    TabItem(id: "g2", title: "g2", groupID: "G"), TabItem(id: "b", title: "b"), TabItem(id: "c", title: "c")]
        return TabStripModel(tabs: tabs, groups: [TabGroupItem(id: "G", isCollapsed: collapsed)], selectedID: selected)
    }

    @Test func nextAndPreviousSkipACollapsedGroup() {
        let strip = model()
        #expect(strip.adjacentVisibleTab(from: "a", offset: 1) == "b")
        #expect(strip.adjacentVisibleTab(from: "b", offset: -1) == "a")
        // Wrapping.
        #expect(strip.adjacentVisibleTab(from: "c", offset: 1) == "a")
        #expect(strip.adjacentVisibleTab(from: "a", offset: -1) == "c")
    }

    @Test func anExpandedGroupIsSteppedThrough() {
        let strip = model(collapsed: false)
        #expect(strip.adjacentVisibleTab(from: "a", offset: 1) == "g1")
        #expect(strip.adjacentVisibleTab(from: "g2", offset: 1) == "b")
        #expect(strip.visibleOrderedTabs.map(\.id) == ["a", "g1", "g2", "b", "c"])
    }

    @Test func fromAHiddenTabTheNextVisibleOneIsChosen() {
        let strip = model(selected: "g1")
        #expect(strip.adjacentVisibleTab(from: "g1", offset: 1) == "b")
        #expect(strip.adjacentVisibleTab(from: "g2", offset: -1) == "a")
    }

    @Test func numbersCountOnlyVisibleTabs() {
        #expect(model().visibleOrderedTabs.map(\.id) == ["a", "b", "c"])
    }

    @Test func everyTabHiddenSelectsNothing() {
        let strip = TabStripModel(tabs: [TabItem(id: "g1", title: "g1", groupID: "G")],
                                  groups: [TabGroupItem(id: "G", isCollapsed: true)], selectedID: "g1")
        #expect(strip.adjacentVisibleTab(from: "g1", offset: 1) == nil)
    }
}

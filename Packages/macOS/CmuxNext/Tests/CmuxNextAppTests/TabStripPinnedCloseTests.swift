@testable import CmuxNextTabs
import Testing

/// Chrome's close rules for pinned tabs (`TabStripModel::GetTabsClosedByCommand`): Close Other
/// Tabs and Close Tabs to the Right never close a pinned tab, and Pin and Unpin move a tab to the
/// end of the pinned tabs or the start of the unpinned ones. Close Tabs to the Right closed the
/// pinned tabs after a right-clicked pinned tab.
@MainActor struct TabStripPinnedCloseTests {
    /// p0 p1 p2 pinned, then t3 t4 t5.
    private func model() -> TabStripModel {
        let tabs = (0..<6).map { TabItem(id: TabID($0 < 3 ? "p\($0)" : "t\($0)"), title: "Tab \($0)", isPinned: $0 < 3) }
        return TabStripModel(tabs: tabs, selectedID: TabID("t4"))
    }

    private func ids(_ raw: String...) -> [TabID] { raw.map { TabID($0) } }

    @Test func closeTabsToTheRightOfAPinnedTabKeepsTheOtherPinnedTabs() {
        #expect(model().closedByCloseToRight(of: TabID("p0")) == ids("t3", "t4", "t5"))
        #expect(model().closedByCloseToRight(of: TabID("t3")) == ids("t4", "t5"))
        #expect(model().closedByCloseToRight(of: TabID("t5")).isEmpty)
    }

    @Test func closeOtherTabsKeepsPinnedTabs() {
        #expect(model().closedByCloseOthers(keeping: TabID("t4")) == ids("t3", "t5"))
        // From a pinned tab: every unpinned tab, no pinned one.
        #expect(model().closedByCloseOthers(keeping: TabID("p1")) == ids("t3", "t4", "t5"))
    }

    @Test func closeTabsToTheLeftKeepsPinnedTabs() {
        #expect(model().closedByCloseToLeft(of: TabID("t5")) == ids("t3", "t4"))
        #expect(model().closedByCloseToLeft(of: TabID("p2")).isEmpty)
    }

    @Test func theLocalReducerFollowsTheSameRules() {
        let right = model()
        right.apply(.closeToRight(of: TabID("p0"))) { TabItem(id: TabID("new"), title: "") }
        #expect(right.orderedTabs.map(\.id) == ids("p0", "p1", "p2"))
        let others = model()
        others.apply(.closeOthers(keeping: TabID("t4"))) { TabItem(id: TabID("new"), title: "") }
        #expect(others.orderedTabs.map(\.id) == ids("p0", "p1", "p2", "t4"))
    }

    @Test func pinMovesATabToTheEndOfThePinnedTabsAndUnpinToTheStartOfTheRest() {
        let strip = model()
        strip.apply(.pin(TabID("t4"))) { TabItem(id: TabID("new"), title: "") }
        #expect(strip.orderedTabs.map(\.id) == ids("p0", "p1", "p2", "t4", "t3", "t5"))
        let firstFourPinned = strip.orderedTabs.prefix(4).allSatisfy { $0.isPinned }
        #expect(firstFourPinned)
        strip.apply(.unpin(TabID("p0"))) { TabItem(id: TabID("new"), title: "") }
        #expect(strip.orderedTabs.map(\.id) == ids("p1", "p2", "t4", "p0", "t3", "t5"))
        let pinned = strip.orderedTabs.filter { $0.isPinned }.map { $0.id }
        #expect(pinned == ids("p1", "p2", "t4"))
    }

    /// Cmd-W with `tabs.cmdWClosesPinnedTabs` on closes a pinned tab, as Chrome's Cmd-W does.
    @Test func cmdWClosesAPinnedTabWhenTheSettingSaysSo() {
        #expect(model().keyboardClose(TabID("p1"), closesPinned: true) == .close)
        #expect(model().keyboardClose(TabID("p1"), closesPinned: false) == .select(TabID("p2")))
    }

    /// Move Tab Left and Move Tab Right stop at the pinned boundary (Chrome): the daemon puts a
    /// pinned tab moved past it back, so Move Right on the last pinned tab did nothing, silently.
    @Test func moveLeftAndRightStayInsideTheTabsSection() {
        let strip = model()
        #expect(strip.moveIndex(of: TabID("p0"), by: 1) == 1)
        #expect(strip.moveIndex(of: TabID("p2"), by: 1) == nil)
        #expect(strip.moveIndex(of: TabID("t3"), by: -1) == nil)
        #expect(strip.moveIndex(of: TabID("t3"), by: 1) == 4)
        #expect(strip.moveIndex(of: TabID("t5"), by: 1) == nil)
        #expect(strip.moveIndex(of: TabID("p0"), by: -1) == nil)
    }
}

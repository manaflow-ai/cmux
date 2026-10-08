import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// PINNED-ITEMS-END-TO-END P3: Cmd-W on a pinned tab selects the next tab
/// and keeps the pinned tab; unpinned tabs close as before.
@Suite("Pinned tab keyboard close")
struct PinnedTabCloseTests {
    private func tab(_ id: String, pinned: Bool = false, group: TabGroupID? = nil) -> TabItem {
        TabItem(id: TabID(id), title: id, icon: .none, isPinned: pinned, groupID: group)
    }

    @Test func unpinnedTabCloses() {
        let model = TabStripModel(tabs: [tab("a", pinned: true), tab("b")], selectedID: TabID("b"))
        #expect(model.keyboardClose(TabID("b")) == .close)
    }

    @Test func pinnedTabSelectsTheNextTab() {
        let model = TabStripModel(tabs: [tab("a", pinned: true), tab("b", pinned: true), tab("c")], selectedID: TabID("a"))
        #expect(model.keyboardClose(TabID("a")) == .select(TabID("b")))
        #expect(model.keyboardClose(TabID("b")) == .select(TabID("c")))
    }

    @Test func lastPinnedTabSelectsThePreviousTab() {
        let onlyPinned = TabStripModel(tabs: [tab("p", pinned: true), tab("q", pinned: true)], selectedID: TabID("q"))
        #expect(onlyPinned.keyboardClose(TabID("q")) == .select(TabID("p")))
    }

    @Test func onlyTabIsKept() {
        let model = TabStripModel(tabs: [tab("p", pinned: true)], selectedID: TabID("p"))
        #expect(model.keyboardClose(TabID("p")) == .keep)
    }

    @Test func tabsInACollapsedGroupAreSkipped() {
        let group = TabGroupID("g")
        let model = TabStripModel(tabs: [tab("p", pinned: true), tab("x", group: group), tab("y")],
                                  groups: [TabGroupItem(id: group, isCollapsed: true)], selectedID: TabID("p"))
        #expect(model.keyboardClose(TabID("p")) == .select(TabID("y")))
    }

    @Test func theSettingLetsCmdWClosePinnedTabs() {
        let model = TabStripModel(tabs: [tab("a", pinned: true), tab("b")], selectedID: TabID("a"))
        #expect(model.keyboardClose(TabID("a"), closesPinned: true) == .close, "tabs.cmdWClosesPinnedTabs on")
        #expect(model.keyboardClose(TabID("a"), closesPinned: false) == .select(TabID("b")), "off (the default) keeps it")
        let only = TabStripModel(tabs: [tab("p", pinned: true)], selectedID: TabID("p"))
        #expect(only.keyboardClose(TabID("p"), closesPinned: true) == .close)
    }

    @Test func unknownTabCloses() {
        let model = TabStripModel(tabs: [tab("p", pinned: true)], selectedID: TabID("p"))
        #expect(model.keyboardClose(TabID("zz")) == .close)
    }
}

import Testing
@testable import CmuxNextSidebar

/// Workspace groups mirror tab-group verbs: pin, close, reopen.
@Suite struct GroupVerbs {
    @Test func closingUnpinnedGroupRemovesIt() {
        var s = fixture()
        SidebarEdits.apply(.closeGroup(g1), to: &s)
        #expect(shape(s, local) == "a b G2[h1,h2] c")
    }

    @Test func settingAGroupIconStoresItAndNilRemovesIt() throws {
        var s = fixture()
        #expect(SidebarEdits.apply(.setGroupIcon(g1, "star.fill"), to: &s))
        var group = try #require(s.flatMap(\.nodes).compactMap { node -> SidebarGroup? in
            if case let .group(group) = node, group.id == g1 { group } else { nil }
        }.first)
        #expect(group.icon == .symbol("star.fill"))
        SidebarEdits.apply(.setGroupIcon(g1, nil), to: &s)
        group = try #require(s.flatMap(\.nodes).compactMap { node -> SidebarGroup? in
            if case let .group(group) = node, group.id == g1 { group } else { nil }
        }.first)
        #expect(group.icon == nil)
    }

    @Test func closingPinnedGroupKeepsEmptySavedGroup() {
        var s = fixture()
        SidebarEdits.apply(.setGroupPinned(g1, true), to: &s)
        SidebarEdits.apply(.closeGroup(g1), to: &s)
        #expect(shape(s, local) == "a G1[] b G2[h1,h2] c")
        let layout = SidebarLayout.make(sections: s, metrics: .standard)
        #expect(layout.row(for: .group(g1))?.isCollapsed == true)
    }

    @Test func savedGroupSurvivesDraggingItsLastWorkspaceOut() {
        var s = fixture()
        SidebarEdits.apply(.setGroupPinned(g2, true), to: &s)
        SidebarEdits.apply(.reorder([id("h1"), id("h2")], to: DropPosition(section: local, index: 0)), to: &s)
        #expect(shape(s, local) == "h1 h2 a G1[g1,g2,g3] b G2[] c")
    }

    @Test func closeGroupMovesActiveSelectionOut() {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("g2"))
        model.apply(.closeGroup(g1))
        #expect(model.activeWorkspaceID != id("g2"))
        #expect(model.activeWorkspaceID != nil)
    }

    @Test func openGroupIsForwardedNotApplied() {
        var s = fixture()
        #expect(!SidebarEdits.apply(.openGroup(g1), to: &s))
    }
}

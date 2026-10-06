import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// `sidebar.showWorkspaceTabs` and `sidebar.showCounts`: a workspace row
/// can show how many tabs it has, and with its tabs listed inline a
/// disclosure on it collapses them.
@Suite struct SidebarWorkspaceTabsTests {
    private func sections() -> [SidebarSection] {
        var sections = fixture()
        sections[1].nodes[0] = .workspace(SidebarWorkspace(
            id: id("a"), title: "a",
            tabs: [SidebarTab(id: TabID("t1"), title: "Terminal"),
                   SidebarTab(id: TabID("t2"), title: "Chat", kind: .agentChat)]
        ))
        sections[1].nodes[1] = .group(SidebarGroup(id: g1, name: "G1", color: .purple, workspaces: [
            SidebarWorkspace(id: id("g1"), title: "g1", tabs: [SidebarTab(id: TabID("t3"), title: "Terminal")]), w("g2"), w("g3"),
        ]))
        return sections
    }

    @Test func offByDefaultRowsHaveNoDisclosureAndNoCount() {
        let layout = SidebarLayout.make(sections: sections(), metrics: .standard)
        let row = layout.row(for: .workspace(id("a")))
        #expect(row?.tabDisclosure == nil)
        #expect(row?.tabCount == nil)
        #expect(layout.row(for: .tab(id("a"), TabID("t1"))) == nil)
    }

    @Test func showWorkspaceTabsListsTabsUnderADisclosure() {
        var options = SidebarLayoutOptions()
        options.showWorkspaceTabs = true
        let open = SidebarLayout.make(sections: sections(), metrics: .standard, options: options)
        #expect(open.row(for: .workspace(id("a")))?.tabDisclosure == .expanded)
        #expect(open.row(for: .tab(id("a"), TabID("t2")))?.tabKind == .agentChat)
        // A workspace in a group gets the same disclosure.
        #expect(open.row(for: .workspace(id("g1")))?.tabDisclosure == .expanded)
        #expect(open.row(for: .tab(id("g1"), TabID("t3"))) != nil)
    }

    @Test func collapsingOneWorkspaceHidesOnlyItsTabs() {
        var options = SidebarLayoutOptions()
        options.showWorkspaceTabs = true
        options.collapsedWorkspaces = [id("a")]
        let layout = SidebarLayout.make(sections: sections(), metrics: .standard, options: options)
        #expect(layout.row(for: .workspace(id("a")))?.tabDisclosure == .collapsed)
        #expect(layout.row(for: .tab(id("a"), TabID("t1"))) == nil)
        #expect(layout.row(for: .tab(id("g1"), TabID("t3"))) != nil)
    }

    @Test func aWorkspaceWithoutTabsHasNothingToDisclose() {
        var options = SidebarLayoutOptions()
        options.showWorkspaceTabs = true
        let layout = SidebarLayout.make(sections: sections(), metrics: .standard, options: options)
        #expect(layout.row(for: .workspace(id("b")))?.tabDisclosure == .empty)
    }

    @Test func countsShowTheWorkspaceTabCount() {
        var options = SidebarLayoutOptions()
        options.showCounts = true
        let layout = SidebarLayout.make(sections: sections(), metrics: .standard, options: options)
        #expect(layout.row(for: .workspace(id("a")))?.tabCount == 2)
        #expect(layout.row(for: .workspace(id("b")))?.tabCount == 0)
    }

    @MainActor @Test func theModelTogglesAWorkspaceClosedAndOpen() {
        let model = SidebarModel(sections: sections())
        model.toggleWorkspaceTabs(id("a"))
        #expect(model.collapsedWorkspaces == [id("a")])
        model.toggleWorkspaceTabs(id("a"))
        #expect(model.collapsedWorkspaces.isEmpty)
    }
}

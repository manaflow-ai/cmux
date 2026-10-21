@testable import CmuxNextSidebar
import Testing

/// One list for a workspace's tabs (Leo 2026-10-20): a workspace showing vertical tabs lists them beside its
/// panes, so the sidebar draws no tab rows and an empty disclosure on its row, even with Show Workspace Tabs on.
/// Other workspaces keep their tab rows.
@MainActor @Suite struct SidebarInWorkspaceTabsTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func sections() -> [SidebarSection] {
        let tabs = [SidebarTab(id: TabID("t1"), title: "One", kind: .browser), SidebarTab(id: TabID("t2"), title: "Two", kind: .browser)]
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("ws_vertical"), title: "Vertical", tabs: tabs)),
            .workspace(SidebarWorkspace(id: WorkspaceID("ws_strip"), title: "Strip", tabs: tabs)),
        ])]
    }

    static func layout(_ tabs: SidebarInWorkspaceTabs) -> SidebarLayout {
        var o = SidebarLayoutOptions()
        o.showWorkspaceTabs = true
        o.inWorkspaceTabs = tabs
        return SidebarLayout.make(sections: sections(), metrics: .standard, options: o)
    }

    static func tabRows(_ layout: SidebarLayout, of id: String) -> Int {
        layout.rows.filter { if case .tab(WorkspaceID(id), _) = $0.key { true } else { false } }.count
    }

    static func disclosure(_ layout: SidebarLayout, of id: String) -> SidebarTabDisclosure? {
        layout.rows.first { $0.key == .workspace(WorkspaceID(id)) }?.tabDisclosure
    }

    @Test func aVerticalTabsWorkspaceListsNoTabRows() {
        let layout = Self.layout(SidebarInWorkspaceTabs(choices: [WorkspaceID("ws_vertical"): true]))
        #expect(Self.tabRows(layout, of: "ws_vertical") == 0)
        #expect(Self.disclosure(layout, of: "ws_vertical") == .empty, "the row keeps the control's place, drawn empty")
        #expect(Self.tabRows(layout, of: "ws_strip") == 2)
        #expect(Self.disclosure(layout, of: "ws_strip") == .expanded)
    }

    @Test func allWorkspacesVerticalListsNoTabRowsExceptAWorkspaceThatTurnedThemOff() {
        let layout = Self.layout(SidebarInWorkspaceTabs(allWorkspaces: true, choices: [WorkspaceID("ws_strip"): false]))
        #expect(Self.tabRows(layout, of: "ws_vertical") == 0)
        #expect(Self.tabRows(layout, of: "ws_strip") == 2)
    }

    @Test func withNoVerticalTabsEveryWorkspaceListsItsTabs() {
        let layout = Self.layout(SidebarInWorkspaceTabs())
        #expect(Self.tabRows(layout, of: "ws_vertical") == 2)
        #expect(Self.tabRows(layout, of: "ws_strip") == 2)
    }
}

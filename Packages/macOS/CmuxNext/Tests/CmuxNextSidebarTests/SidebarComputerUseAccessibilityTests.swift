import AppKit
import Testing

@testable import CmuxNextSidebar

/// Computer-use contract tests for native next-sidebar workspace and tab rows.
@MainActor @Suite(.serialized)
struct SidebarComputerUseAccessibilityTests {
    @Test
    func workspaceRowExposesStableIdentityLabelAndAXPress() throws {
        let id = WorkspaceID("ws_cua")
        let row = Self.row(key: .workspace(id))
        let workspace = SidebarWorkspace(id: id, title: "Computer Use")
        let view = WorkspaceRowView(key: row.key)
        var selected = false
        view.onSelect = { selected = true }
        view.configure(workspace, row: row)

        #expect(view.accessibilityIdentifier() == "cmux.sidebar.workspace.ws_cua")
        #expect(view.accessibilityLabel()?.contains("Computer Use") == true)
        #expect(view.accessibilityPerformPress())
        #expect(selected)
    }

    @Test
    func tabRowExposesStableIdentityLabelAndAXPress() throws {
        let workspaceID = WorkspaceID("ws_cua")
        let tabID = TabID("tab_terminal")
        let row = Self.row(key: .tab(workspaceID, tabID), tabKind: .terminal)
        let view = SidebarTabRowView(key: row.key)
        var selected = false
        view.onSelect = { selected = true }
        view.configure(SidebarTab(id: tabID, title: "Shell"), row: row)

        #expect(view.accessibilityIdentifier() == "cmux.sidebar.tab.ws_cua.tab_terminal")
        #expect(view.accessibilityLabel() == "Shell")
        #expect(view.accessibilityPerformPress())
        #expect(selected)
    }

    private static func row(
        key: SidebarRowKey,
        tabKind: SidebarTabKind? = nil
    ) -> SidebarRow {
        SidebarRow(
            key: key,
            y: 0,
            height: 36,
            section: .machine(.local),
            group: nil,
            workspace: {
                if case let .tab(workspaceID, _) = key { return workspaceID }
                return nil
            }(),
            siblingIndex: 0,
            parentIndex: nil,
            isLastInGroup: true,
            isCollapsed: false,
            childCount: 0,
            groupColor: nil,
            tabKind: tabKind,
            titlesProjects: false,
            tabDisclosure: nil,
            content: nil
        )
    }
}

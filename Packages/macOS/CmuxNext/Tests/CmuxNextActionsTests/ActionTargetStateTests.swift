import AppKit
import CmuxNextActions
import Testing

/// A context menu toggle shows its state as a checkmark (Show Tabs Under
/// Workspaces in the sidebar's menus; Leo 2026-10-09); an action without a
/// state keeps a plain row.
@MainActor
@Suite struct ActionTargetStateTests {
    private static let id: ActionID = "sidebar.workspaceTabs.toggle"

    private func item(_ registry: ActionRegistry, _ menu: ActionMenuContext) throws -> NSMenuItem {
        let title = try #require(registry.title(for: Self.id))
        let items = registry.makeContextMenu(for: menu).items
        return try #require(items.first { $0.title == title })
    }

    @Test func theToggleIsInTheSidebarAndWorkspaceRowMenus() {
        func ids(_ menu: ActionMenuContext) -> [ActionID] {
            ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: menu))
        }
        #expect(ids(.sidebarBackground).contains(Self.id))
        #expect(ids(.workspaceRow).contains(Self.id))
        #expect(ActionRegistry.standard().title(for: Self.id) == "Show Tabs Under Workspaces")
    }

    @Test func theMenuItemIsCheckedWhileTheStateIsOn() throws {
        let registry = ActionRegistry.standard()
        registry.bind(Self.id, invoke: { _ in })
        var on = false
        ActionTargetTitles.setState(Self.id, in: registry) { _ in on }
        #expect(try item(registry, .sidebarBackground).state == .off)
        on = true
        #expect(try item(registry, .sidebarBackground).state == .on)
    }

    @Test func anActionWithoutAStateIsNotChecked() throws {
        let registry = ActionRegistry.standard()
        registry.bind(Self.id, invoke: { _ in })
        #expect(try item(registry, .sidebarBackground).state == .off)
    }
}

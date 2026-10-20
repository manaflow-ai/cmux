@testable import CmuxNextActions
import Testing

/// Every sidebar ordering and organizing verb (plans/cmux-next/sidebar-ordering-AUDIT.md, Lawrence
/// 2026-10-19: "I need an option to move a group to the top and move a workspace to the top of a
/// group … add all of them") is one catalog action offered in its object's right-click and ···
/// menu, the palette, the CLI and MCP. The menus are generated, so a verb reached from the menu
/// runs the same registered action as the palette, the CLI and MCP
/// (`ActionSurfaceParityTests.everyMenuItemRunsItsOwnActionThroughTheRegistry`).
@MainActor @Suite struct SidebarOrderingSurfacesTests {
    /// A group's verbs, as its menu shows them.
    nonisolated static let groupMenu: [ActionID] = [
        "workspaceGroup.moveToTop", "workspaceGroup.moveToBottom", "workspaceGroup.moveUp", "workspaceGroup.moveDown",
        "workspaceGroup.rename", "workspaceGroup.setColor", "toggleFocusedWorkspaceGroupCollapsed", "workspaceGroup.collapseOthers",
        "workspaceGroup.ungroup", "workspaceGroup.closeWorkspaces", "workspaceGroup.duplicate", "workspaceGroup.newWorkspace",
        "workspaceGroup.sortByName", "workspaceGroup.sortByLastUsed", "workspaceGroup.sortByDirectory",
    ]
    /// A workspace row's verbs, as its menu shows them.
    nonisolated static let workspaceMenu: [ActionID] = [
        "palette.moveWorkspaceToTop", "workspace.moveToBottom", "moveWorkspaceUp", "moveWorkspaceDown", "moveWorkspaceToGroup",
        "workspace.moveToNewGroup", "removeWorkspaceFromGroup", "palette.toggleWorkspacePin", "workspace.duplicate",
        "workspace.closeOthersInGroup",
    ]
    /// Collapse/Expand is one toggle in the menu; the CLI and MCP run its two directions.
    nonisolated static let scripted: [ActionID] = (groupMenu + workspaceMenu).filter { $0 != "toggleFocusedWorkspaceGroupCollapsed" }
        + ["workspaceGroup.collapse", "workspaceGroup.expand"]

    @Test(arguments: groupMenu.map { ($0, ActionMenuContext.workspaceGroup) } + workspaceMenu.map { ($0, ActionMenuContext.workspaceRow) })
    func verbIsInItsObjectsMenu(_ id: ActionID, _ context: ActionMenuContext) {
        let shown = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context))
        #expect(shown.contains(id), "\(id) is not in the \(context) menu")
    }

    @Test(arguments: scripted)
    func verbIsInThePaletteTheCLIAndMCP(_ id: ActionID) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is no catalog action")
        let plan = descriptor.surfacePlan
        #expect(plan.palette.isOffered, "\(id): not in the palette")
        #expect(plan.cli?.isOffered == true, "\(id): no CLI verb")
        #expect(plan.mcp?.isOffered == true, "\(id): no MCP tool")
    }

    /// The group verbs a person reorders with can take a shortcut in Settings and cmux.json.
    @Test(arguments: ["workspaceGroup.moveToTop", "workspaceGroup.moveToBottom", "workspaceGroup.moveUp", "workspaceGroup.moveDown",
                      "palette.moveWorkspaceToTop", "workspace.moveToBottom"] as [ActionID])
    func reorderVerbTakesAShortcut(_ id: ActionID) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
        #expect(descriptor.surfaces.contains(.keyboard), "\(id) cannot take a shortcut")
    }

    /// Move ▸ (Top, Up, Down, Bottom) is a top-level row of the workspace menu, not inside More.
    @Test func workspaceMenuShowsMoveAtTheTopLevel() throws {
        let entries = ContextMenuCatalog.shared.entries(for: .workspaceRow)
        let move = try #require(entries.lazy.compactMap { entry -> [ContextMenuEntry]? in
            if case .folder(.move, let children) = entry { children } else { nil }
        }.first, "the workspace menu has no top-level Move folder")
        let ids = ContextMenuCatalog.shared.referencedIDs(move)
        for id: ActionID in ["palette.moveWorkspaceToTop", "moveWorkspaceUp", "moveWorkspaceDown", "workspace.moveToBottom"] {
            #expect(ids.contains(id), "Move ▸ lacks \(id)")
        }
    }

    /// The group's Move ▸ lists Top, Up, Down, Bottom in that order.
    @Test func groupMoveFolderOrdersTopUpDownBottom() throws {
        let entries = ContextMenuCatalog.shared.entries(for: .workspaceGroup)
        let move = try #require(entries.lazy.compactMap { entry -> [ContextMenuEntry]? in
            if case .folder(.move, let children) = entry { children } else { nil }
        }.first, "the group menu has no Move folder")
        let ids = ContextMenuCatalog.shared.referencedIDs(move)
        let order: [ActionID] = ["workspaceGroup.moveToTop", "workspaceGroup.moveUp", "workspaceGroup.moveDown", "workspaceGroup.moveToBottom"]
        #expect(Array(ids.filter(order.contains)) == order, "group Move ▸ order: \(ids)")
    }
}

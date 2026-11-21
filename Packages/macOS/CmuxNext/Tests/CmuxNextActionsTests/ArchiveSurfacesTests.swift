import AppKit
@testable import CmuxNextActions
import Testing

/// Archiving sidebar items (plans/cmux-next/archiving-DESIGN.md): each archivable object has one
/// Archive/Unarchive action, offered in its right-click menu (a workspace row's closing section, a group's
/// Options, a link or tab row's menu), Cmd-Shift-P, the CLI and MCP.
@MainActor @Suite struct ArchiveSurfacesTests {
    nonisolated static let actions: [(ActionID, ActionMenuContext)] = [
        ("workspace.toggleArchive", .workspaceRow), ("workspaceGroup.toggleArchive", .workspaceGroup),
        ("sidebar.item.toggleArchive", .sidebarItem),
    ]

    @Test(arguments: actions)
    func archiveIsInItsObjectsMenuThePaletteTheCLIAndMCP(_ id: ActionID, _ context: ActionMenuContext) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == id }, "\(id) is no catalog action")
        let plan = descriptor.surfacePlan
        #expect(plan.palette.isOffered, "\(id): not in Cmd-Shift-P")
        #expect(plan.cli?.isOffered == true, "\(id): no CLI verb")
        #expect(plan.mcp?.isOffered == true, "\(id): no MCP tool")
        let shown = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context))
        #expect(shown.contains(id), "\(id) is not in the \(context) menu")
    }

    /// #48536: a workspace row's menu shows Archive at its top level, just above Close Workspace, and
    /// runs the row's own Archive/Unarchive; it was only under More, where people did not find it.
    @Test func theWorkspaceMenuShowsArchiveJustAboveClose() throws {
        let registry = ActionRegistry.standard()
        let target = ActionTargetRef(kind: .workspace, id: "ws")
        let menu = registry.makeContextMenu(for: .workspaceRow, target: target)
        let top = menu.items.map { ActionRegistry.menuRun(of: $0)?.id }
        let archive = try #require(top.firstIndex(of: "workspace.toggleArchive"), "Archive is not at the workspace menu's top level")
        #expect(top.indices.contains(archive + 1) && top[archive + 1] == "closeWorkspace", "Archive is not just above Close Workspace")
        #expect(archive > 0 && menu.items[archive - 1].isSeparatorItem, "Archive does not start the closing section")
        let run = try #require(ActionRegistry.menuRun(of: menu.items[archive]))
        #expect(run.target == target, "Archive does not act on the right-clicked row")
        let more = try #require(menu.items.first { $0.title == MenuFolder.more.title }?.submenu)
        #expect(!more.items.contains { ActionRegistry.menuRun(of: $0)?.id == "workspace.toggleArchive" }, "Archive is still in More too")
    }

    /// Archive adds no top-level row past the menu's cap (`everyMenuKeepsAShortTopLevel`): 12, and 13 for
    /// the workspace row, whose top level also has Copy ▸ and now Archive above Close.
    @Test(arguments: actions.map(\.1))
    func theMenuKeepsAShortTopLevel(_ context: ActionMenuContext) {
        let rows = ContextMenuCatalog.shared.entries(for: context).compactMap { entry -> String? in
            switch entry {
            case let .action(id), let .choices(id), let .submenu(id, _): id.rawValue
            case let .folder(folder, _): "\(folder)"
            case let .group(group, _): group.key
            case .separator: nil
            }
        }
        let cap = context == .workspaceRow ? 13 : 12
        #expect(rows.count <= cap, "\(context) has \(rows.count) top-level rows: \(rows)")
    }
}

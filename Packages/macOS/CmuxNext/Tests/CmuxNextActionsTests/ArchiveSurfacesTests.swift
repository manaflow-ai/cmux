@testable import CmuxNextActions
import Testing

/// Archiving sidebar items (plans/cmux-next/archiving-DESIGN.md): each archivable object has one
/// Archive/Unarchive action, offered in its right-click menu (a workspace row's More, a group's
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

    /// Archive adds no top-level row past the 12-row cap (`everyMenuKeepsAShortTopLevel`).
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
        #expect(rows.count <= 12, "\(context) has \(rows.count) top-level rows: \(rows)")
    }
}

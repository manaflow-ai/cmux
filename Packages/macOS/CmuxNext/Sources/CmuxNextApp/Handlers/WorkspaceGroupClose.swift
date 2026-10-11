import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// Close All Workspaces in Group (RECOVERABLE-BY-DEFAULT, Lawrence
/// 2026-10-07: closes run at once, no question of their own): the
/// workspaces close, and a person's gesture gets "Closed the workspaces in
/// “X”" with Undo in its window. Undo (and Cmd-Z, TOAST-UNDO-KEY) reopens
/// the workspaces this close put in the daemon's closed history, then the
/// group when the close deleted it (an unpinned group). Automation (CLI,
/// agents) gets no toast; Reopen Closed Workspace and History still have
/// the items.
@MainActor
enum WorkspaceGroupClose {
    static let toastID = "workspace-group-closed"

    /// The open workspaces the sidebar shows in `group`, with their daemons.
    static func members(of group: WorkspaceGroupModel, _ context: AppActionContext) -> [(WorkspaceModel, DaemonService)] {
        guard let sidebar = try? context.sidebar() else { return [] }
        let rows = sidebar.model.group(CmuxNextSidebar.GroupID(group.id.rawValue))?.workspaces ?? []
        return rows.compactMap { context.services.machines.workspace(id: $0.id.rawValue) }
    }

    static func close(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let group = try context.group(invocation)
        let sidebar = try context.sidebar()
        let services = context.services
        let count = members(of: group, context).count
        let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
        sidebar.handle(.closeGroup(CmuxNextSidebar.GroupID(group.id.rawValue)))
        guard invocation.origin == .user, count > 0, let window = context.activeWindow?.window else { return }
        let name = group.name.isEmpty ? ConfirmationStrings.unnamedGroup : group.name
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: closedToast(name), action: .undo()), in: window)
        let groupID = group.id.rawValue
        handle.onAction = { [weak services] in
            guard let services else { return }
            reopen(group: groupID, workspaces: count, after: seen, services)
        }
    }

    /// Reopens what this close recorded: at most `count` workspace items
    /// that were not in history before (`seen`), oldest first so each
    /// returns to its place, then the group's own record.
    private static func reopen(group id: String, workspaces count: Int, after seen: Set<String>, _ services: AppServices) {
        let fresh = DaemonClosedHistory.entries([.workspace], in: services).filter { !seen.contains($0.item.id) }
        let workspaces = fresh.filter { $0.item.group == nil }.prefix(count)
        for entry in workspaces.reversed() { DaemonClosedHistory.reopen(entry, services: services) }
        if let group = fresh.first(where: { $0.item.group?.id == id }) { DaemonClosedHistory.reopen(group, services: services) }
    }

    static func closedToast(_ name: String) -> String {
        String(format: String(localized: "workspaceGroup.closedToast", defaultValue: "Closed the workspaces in “%@”",
                              table: "Handlers", bundle: .module), name)
    }
}

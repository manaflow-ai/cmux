import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation

/// Close Workspaces in Group (RECOVERABLE-BY-DEFAULT, Lawrence
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
        let rows = sidebar.model.group(sidebar.model.groupID(personal: group.id.rawValue))?.workspaces ?? []
        return rows.compactMap { context.services.machines.workspace(id: $0.id.rawValue) }
    }

    static func close(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let group = try context.group(invocation)
        let sidebar = try context.sidebar()
        let services = context.services
        // The closed items carry the workspace's name, not its id: match on
        // the members' names among the items this close adds (never older ones).
        let closing = members(of: group, context)
        let names = closing.map { $0.0.name }
        let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
        sidebar.handle(.closeGroup(sidebar.model.groupID(personal: group.id.rawValue)))
        guard invocation.origin == .user, !names.isEmpty,
              let window = WorkspaceBulkClose.survivor(closing: closing.map(\.0.id), context) else { return }
        offerUndo(toastID, closedToast(group.name.isEmpty ? ConfirmationStrings.unnamedGroup : group.name), groups: [(group.id.rawValue, names)],
                  after: seen, in: window, services)
    }

    /// The close toast in `window`; its Undo reopens what this close recorded
    /// (`reopen`). Also the bulk closes' toast (`WorkspaceBulkClose`, no group). `undone` runs when its Undo does.
    static func offerUndo(_ id: String, _ message: String, groups: [(String?, [String])], after seen: Set<String>,
                          in window: NSWindow, _ services: AppServices, undone: (@MainActor () -> Void)? = nil) {
        // Too soon after the last one: Reopen Closed and History still bring the workspaces back.
        if let undoToasts = services.closedTabs?.undoToasts, !CmuxToastCenter.shared.toasts(in: window).contains(where: { $0.id == id }),
           !undoToasts.allowsNewToast(id) { return }
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: id, message: message, action: .undo()), in: window)
        handle.onAction = { [weak services] in
            undone?()
            guard let services else { return }
            // task-owner: one undo, bounded by `arrivalLimit`
            Task { @MainActor in for (group, names) in groups { await reopen(group: group, names: names, after: seen, services) } }
        }
    }

    /// How long an Undo pressed right after the close waits for the
    /// daemon's closed items to reach the store.
    static let arrivalLimit: Duration = .seconds(5)

    /// The closed items of this close: the new workspace items (newest first)
    /// whose members carry the closing workspaces' names, each name taken
    /// once (one bulk close is one item of several members, `BulkClosePlan`;
    /// an older daemon stores one item per workspace), the names no item took
    /// yet, and the group's own record.
    nonisolated static func matching(names: [String], group id: String?, fresh: [ClosedItem])
        -> (workspaces: [String], missing: [String], group: String?) {
        var wanted = names
        var workspaces: [String] = []
        for item in fresh where item.kind == .workspace && item.group == nil {
            let carried = item.memberNames.isEmpty ? [item.name] : item.memberNames
            var took = false
            for name in carried {
                guard let index = wanted.firstIndex(of: name ?? "") else { continue }
                wanted.remove(at: index)
                took = true
            }
            if took { workspaces.append(item.id) }
        }
        return (workspaces, wanted, id.flatMap { id in fresh.first { $0.group?.id == id }?.id })
    }

    private static func matches(names: [String], group id: String?, after seen: Set<String>,
                                _ services: AppServices) -> (workspaces: [String], missing: [String], group: String?) {
        let fresh = DaemonClosedHistory.entries([.workspace], in: services).map(\.item).filter { !seen.contains($0.id) }
        return matching(names: names, group: id, fresh: fresh)
    }

    /// Reopens what this close recorded once every member's item is in the
    /// store (or `arrivalLimit` passed): the workspaces oldest first, so each
    /// returns to its place, then the group's own record (none for a bulk close, `WorkspaceBulkClose`).
    private static func reopen(group id: String?, names: [String], after seen: Set<String>, _ services: AppServices) async {
        let arrived: @MainActor @Sendable () -> Bool = { [weak services] in
            guard let services else { return true }
            return matches(names: names, group: id, after: seen, services).missing.isEmpty
        }
        if !arrived() { await ObservationDeadline(owner: "workspace-group-close-undo").until(arrived, limit: arrivalLimit) }
        let found = matches(names: names, group: id, after: seen, services)
        for itemID in found.workspaces.reversed() {
            if let entry = DaemonClosedHistory.entry(itemID, in: services) { DaemonClosedHistory.reopen(entry, services: services) }
        }
        if let id, let groupItem = found.group, let entry = DaemonClosedHistory.groupEntry(id, in: services), entry.item.id == groupItem {
            DaemonClosedHistory.reopen(entry, services: services)
        }
    }

    static func closedToast(_ name: String) -> String {
        String(format: String(localized: "workspaceGroup.closedToast", defaultValue: "Closed the workspaces in “%@”",
                              table: "Handlers", bundle: .module), name)
    }
}

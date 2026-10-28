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
    /// (`reopen`). Also the bulk closes' toast (`WorkspaceBulkClose`, no group).
    static func offerUndo(_ id: String, _ message: String, groups: [(String?, [String])], after seen: Set<String>,
                          in window: NSWindow, _ services: AppServices, action: CmuxToast.Action = .undo(),
                          duration: Duration = .seconds(6)) {
        // Too soon after the last one: Reopen Closed and History still bring the workspaces back.
        if let undoToasts = services.closedTabs?.undoToasts, !CmuxToastCenter.shared.toasts(in: window).contains(where: { $0.id == id }),
           !undoToasts.allowsNewToast(id) { return }
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: id, message: message, action: action, duration: duration), in: window)
        handle.onAction = { [weak services] in
            guard let services else { return }
            // One undo (the person's click), bounded by `arrivalLimit`: the waits are awaited off main, each reopen runs on main.
            services.registry.completion(on: services.mainWork).start {
                for (group, names) in groups { await reopen(group: group, names: names, after: seen, services) }
            }
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
        // One ServiceObservation reads the closed items again only when the store's history changes.
        await ObservedCondition(owner: "workspace-group-close-undo", .visible, on: services.mainWork)
            .until(timeout: arrivalLimit, deadlines: services.mainDeadlines, arrived)
        let found = matches(names: names, group: id, after: seen, services)
        for itemID in found.workspaces.reversed() {
            if let entry = DaemonClosedHistory.entry(itemID, in: services) { DaemonClosedHistory.reopen(entry, services: services) }
        }
        if let id, let groupItem = found.group, let entry = DaemonClosedHistory.groupEntry(id, in: services), entry.item.id == groupItem {
            DaemonClosedHistory.reopen(entry, services: services)
        }
    }

    /// The toast of a person's close of one workspace (``offerWorkspaceUndo(closing:from:_:)``).
    static let workspaceToastID = "workspace-closed"
    /// How long it shows (audit-findings-1 C: 5 s).
    static let workspaceToastDuration: Duration = .seconds(5)

    /// A person's Close Workspace (Cmd-Shift-W, Cmd-W on its last tab, a row's close button), audit-findings-1 C:
    /// "Workspace closed" with "Undo (⇧⌘T)" for 5 s, in the window that showed it when that window stays (it shows its
    /// next row or Home), else in a window that stays. Undo (its button, Cmd-Z) reopens this close's item from the
    /// daemon's closed history, as Cmd-Shift-T does: the layout, tabs, scrollback and cwd. Called once the close is
    /// sent (after the question, when one asked), before the daemon records it.
    static func offerWorkspaceUndo(closing workspace: WorkspaceModel, from controller: WindowController?, _ services: AppServices) {
        let id = workspace.id, windows = services.windows
        let staysOpen = { (window: WindowController) in windows.registry.members(of: window.state.id).contains { $0 != id } }
        guard let window = (controller.flatMap { staysOpen($0) ? $0.window : nil }
            ?? windows.controllers.first(where: staysOpen)?.window) else { return }
        let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
        let undo = services.registry.shortcutDisplay(for: "reopenClosedBrowserPanel").map(undoTitle) ?? CmuxToastStrings.undo
        offerUndo(workspaceToastID, workspaceClosedToast, groups: [(nil, [workspace.name])], after: seen, in: window, services,
                  action: .undo(undo), duration: workspaceToastDuration)
    }

    static var workspaceClosedToast: String {
        String(localized: "workspace.closedToast", defaultValue: "Workspace closed", table: "Handlers", bundle: .module)
    }

    /// The Undo button with the key that reopens it, "Undo (⇧⌘T)".
    static func undoTitle(_ key: String) -> String {
        String(format: String(localized: "workspace.closedToast.undo", defaultValue: "Undo (%@)", table: "Handlers", bundle: .module), key)
    }

    static func closedToast(_ name: String) -> String {
        String(format: String(localized: "workspaceGroup.closedToast", defaultValue: "Closed the workspaces in “%@”",
                              table: "Handlers", bundle: .module), name)
    }
}

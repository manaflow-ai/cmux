import AppKit
import CmuxNextActions
import CmuxNextAppCore
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWindowRules
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
        let window = WorkspaceBulkClose.survivor(closing: closing.map(\.0.id), context)
        guard WindowRules().groupCloseOffersUndo(user: invocation.origin == .user, names: names.count, survivor: window != nil), let window else { return } // handlers_close_group_offers_undo
        offerUndo(toastID, closedToast(group.name.isEmpty ? ConfirmationStrings.unnamedGroup : group.name), groups: [(group.id.rawValue, names)],
                  after: seen, in: window, services)
    }

    /// The close toast in `window`; its Undo reopens what this close recorded
    /// (`reopen`). Also the bulk closes' toast (`WorkspaceBulkClose`, no group). `undone` runs when its Undo does.
    /// Undo stops or waits for each of `cleanups` (`closeCleanups`), reopening each deleted group's record before the workspaces.
    static func offerUndo(_ id: String, _ message: String, groups: [(String?, [String])], after seen: Set<String>,
                          in window: NSWindow, _ services: AppServices, cleanups: [GroupCloseCleanup] = [],
                          toasts: CmuxToastCenter = .shared, undone: (@MainActor () -> Void)? = nil) {
        // Too soon after the last one: Reopen Closed and History still bring the workspaces back.
        if let undoToasts = services.closedTabs?.undoToasts, !toasts.toasts(in: window).contains(where: { $0.id == id }),
           !undoToasts.allowsNewToast(id) { return }
        let handle = toasts.show(CmuxToast(id: id, message: message, action: .undo()), in: window)
        handle.onAction = { [weak services] in
            undone?()
            guard let services else { return }
            // task-owner: one undo, bounded by `arrivalLimit`
            Task { @MainActor in
                // A deleted group's record is restored (awaited) first: it regroups the closed workspaces' kept rows,
                // which their reopens keep; restored after them it would find their rows under new keys.
                for cleanup in cleanups {
                    if let record = await cleanup.undo(limit: arrivalLimit), let entry = DaemonClosedHistory.entry(record, in: services) {
                        _ = try? await entry.daemon.connection?.state.reopenClosed(record)
                    }
                }
                for (group, names) in groups { await reopen(group: group, names: names, after: seen, services) }
            }
        }
    }

    /// How long an Undo pressed right after the close waits for the
    /// daemon's closed items to reach the store.
    static let arrivalLimit: Duration = .seconds(5)

    /// One cleanup per personal group the close of `ids` may empty (`GroupCloseCleanup`), shared with its Undo.
    static func closeCleanups(_ ids: [String], _ services: AppServices) -> [GroupCloseCleanup] {
        let life = PersonalGroupLife(machines: services.machines)
        return life.groupsClosing(ids).sorted { $0.rawValue < $1.rawValue }.map { group in
            life.closeCleanup(group, history: { [weak services] in
                services.map { DaemonClosedHistory.entries([.workspace], in: $0).map { ($0.item.id, $0.item.group?.id) } } ?? []
            }, failed: { [weak services] _ in services?.windows.active?.sidebar.resync() })
        }
    }

    private static func matches(names: [String], group id: String?, after seen: Set<String>,
                                _ services: AppServices) -> ClosedItemMatch {
        let fresh = DaemonClosedHistory.entries([.workspace], in: services).map(\.item).filter { !seen.contains($0.id) }
        return ClosedItemMatch(names: names, group: id, fresh: fresh)
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

    static let singleCloseToastID = "workspace-closed"

    /// Toasts v2 (Leo: "closing a tab or workspace, or archiving a session, shows a one-line toast with an inline
    /// Undo"): a person's close of one workspace, read at the press. `offer` once the close goes ahead shows
    /// "Closed “name”" through ``offerUndo``; `withdraw` when the daemon refuses. Nil when off, for automation, or
    /// when no window keeps a workspace.
    static func singleCloseUndo(_ workspace: WorkspaceModel, _ invocation: ActionInvocation, _ services: AppServices,
                                toasts: CmuxToastCenter = .shared, in window: NSWindow? = nil) -> (offer: @MainActor () -> Void, withdraw: @MainActor () -> Void)? {
        guard toasts.v2, invocation.origin == .user,
              let window = window ?? WorkspaceBulkClose.survivor(closing: [workspace.id], AppActionContext(services: services)) else { return nil }
        let name = workspace.name, seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
        let offer: @MainActor () -> Void = { [weak services] in
            guard let services else { return }
            offerUndo(singleCloseToastID, MiscHandlerStrings.tabClosed(name.isEmpty ? MiscHandlerStrings.untitledWorkspace : name),
                      groups: [(nil, [name])], after: seen, in: window, services, toasts: toasts)
        }
        return (offer, { @MainActor in _ = toasts.close(id: singleCloseToastID, in: window) })
    }

    static func closedToast(_ name: String) -> String {
        String(format: String(localized: "workspaceGroup.closedToast", defaultValue: "Closed the workspaces in “%@”",
                              table: "Handlers", bundle: .module.inAppLanguage), name)
    }
}

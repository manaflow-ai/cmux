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
    @discardableResult
    static func offerUndo(_ id: String, _ message: String, groups: [(String?, [String])], after seen: Set<String>,
                          in window: NSWindow, _ services: AppServices, action: CmuxToast.Action = .undo(),
                          duration: Duration = .seconds(6), joining: Bool = false) -> CmuxToastHandle? {
        // Too soon after the last one: Reopen Closed and History still bring the workspaces back. A join (a close that
        // grows a toast it already showed) is never limited.
        if !joining, let undoToasts = services.closedTabs?.undoToasts, !CmuxToastCenter.shared.toasts(in: window).contains(where: { $0.id == id }),
           !undoToasts.allowsNewToast(id) { return nil }
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: id, message: message, action: action, duration: duration), in: window)
        handle.onAction = { [weak services] in
            guard let services else { return }
            // One undo (the person's click), bounded by `arrivalLimit`: the waits are awaited off main, each reopen runs on main.
            services.registry.completion(on: services.mainWork).start {
                for (group, names) in groups { await reopen(group: group, names: names, after: seen, services) }
            }
        }
        return handle
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

    /// The toast of a person's close of one workspace (``offerWorkspaceUndo(closing:in:from:_:)``).
    static let workspaceToastID = "workspace-closed"
    /// How long it shows (audit-findings-1 C: 5 s).
    static let workspaceToastDuration: Duration = .seconds(5)

    /// One person's close gesture and its undo toast: one row (Cmd-Shift-W, Cmd-W on the last tab, a row's close
    /// button), or several rows closed together (the sidebar's selection), whose toast each row joins once its close
    /// is sent. Undo reopens the rows still in it.
    final class UndoBatch {
        var names: [(id: String, name: String)] = []
        let seen: Set<String>
        let several: Bool
        weak var handle: CmuxToastHandle?
        weak var window: NSWindow?
        init(seen: Set<String>, several: Bool) {
            self.seen = seen
            self.several = several
        }
    }
    /// A several-row close: each row's Close Workspace runs in `body` with the batch's id
    /// (`ActionInvocation.closeBatch`) and takes the batch in its own turn (``undoBatch(_:_:)``); the table holds it only
    /// for that loop.
    static func withUndoBatch(_ services: AppServices, _ body: (String) -> Void) {
        let id = UUID().uuidString
        services.closedTabs?.undoToasts.workspaceBatches[id] = UndoBatch(seen: closedIDs(services), several: true)
        defer { services.closedTabs?.undoToasts.workspaceBatches[id] = nil }
        body(id)
    }

    /// The batch a close joins: its several-row close's, else a new one of its own.
    static func undoBatch(_ id: String?, _ services: AppServices) -> UndoBatch {
        id.flatMap { services.closedTabs?.undoToasts.workspaceBatches[$0] } ?? UndoBatch(seen: closedIDs(services), several: false)
    }

    private static func closedIDs(_ services: AppServices) -> Set<String> {
        Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
    }

    /// A person's close of `workspace` was sent (audit-findings-1 C): its batch's toast shows or grows. One row:
    /// "Workspace closed" with "Undo (⇧⌘T)" for 5 s; several: "Closed N workspaces". It shows in the window that showed
    /// the workspace when that window stays (it shows its next row or Home), else the most recent normal window that
    /// stays. Undo (its button, Cmd-Z) reopens the batch's items from the daemon's closed history, as Cmd-Shift-T does:
    /// the layout, tabs, scrollback and cwd. Nothing for an incognito workspace or a daemon without closed history.
    static func offerWorkspaceUndo(closing workspace: WorkspaceModel, in batch: UndoBatch, from controller: WindowController?,
                                   _ services: AppServices) {
        let id = workspace.id, windows = services.windows
        guard !windows.isIncognito(workspace: id), services.machines.daemon(forWorkspace: id)?.store.servesStateResources == true else { return }
        batch.names.append((id, workspace.name))
        show(batch, near: controller, services)
    }

    /// The close of `id` was refused: it leaves its batch, whose toast goes when no row is left.
    static func withdraw(_ id: String, from batch: UndoBatch, _ services: AppServices) {
        guard batch.names.contains(where: { $0.id == id }) else { return }
        batch.names.removeAll { $0.id == id }
        // Only a toast that still shows changes; one that ended (timed out, closed, replaced) stays ended.
        guard batch.handle?.isDismissed == false else { return }
        if batch.names.isEmpty { batch.handle?.dismiss() } else { show(batch, near: nil, services) }
    }

    /// Shows `batch`'s toast for its rows now (a new toast replaces the one this batch showed).
    private static func show(_ batch: UndoBatch, near controller: WindowController?, _ services: AppServices) {
        let windows = services.windows, registry = windows.registry.value, closing = Set(batch.names.map(\.id))
        let staysOpen = { (window: String) in windows.registry.members(of: window).contains { !closing.contains($0) } }
        let here = controller.flatMap { staysOpen($0.state.id) && !registry.isIncognito($0.state.id) ? $0 : nil }
        // The window the batch's toast shows in keeps it while that window stays.
        let shown = windows.controllers.first { $0.window === batch.window && $0.window != nil && staysOpen($0.state.id) }
        let other = registry.mostRecentOpen(excluding: Set(registry.openWindows.map(\.id).filter { !staysOpen($0) })).flatMap(windows.controller(for:))
        guard let window = (shown ?? here ?? other)?.window else { return }
        let joining = batch.handle?.isDismissed == false
        let undo = services.registry.shortcutDisplay(for: "reopenClosedBrowserPanel").map(undoTitle) ?? CmuxToastStrings.undo
        // A batch keeps one toast id, so its next show replaces its toast in place (and passes the rate limit); a toast
        // it showed in another window goes.
        if let shown = batch.handle, batch.window !== window { shown.dismiss() }
        batch.window = window
        let count = batch.names.count
        batch.handle = offerUndo(batch.several ? "workspaces-closed" : workspaceToastID,
                                 count == 1 ? workspaceClosedToast : WorkspaceBulkClose.closedToast(count),
                                 groups: [(nil, batch.names.map(\.name))], after: batch.seen, in: window, services,
                                 action: .undo(undo), duration: workspaceToastDuration, joining: joining)
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

import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups
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
        // The closed items carry the workspace's name, not its id: match on
        // the members' names among the items this close adds (never older ones).
        let names = members(of: group, context).map { $0.0.name }
        let seen = Set(DaemonClosedHistory.entries([.workspace], in: services).map(\.item.id))
        sidebar.handle(.closeGroup(CmuxNextSidebar.GroupID(group.id.rawValue)))
        guard invocation.origin == .user, !names.isEmpty, let window = context.activeWindow?.window else { return }
        let name = group.name.isEmpty ? ConfirmationStrings.unnamedGroup : group.name
        let handle = CmuxToastCenter.shared.show(CmuxToast(id: toastID, message: closedToast(name), action: .undo()), in: window)
        let groupID = group.id.rawValue
        handle.onAction = { [weak services] in
            guard let services else { return }
            // task-owner: one undo, bounded by `arrivalLimit`
            Task { @MainActor in await reopen(group: groupID, names: names, after: seen, services) }
        }
    }

    /// How long an Undo pressed right after the close waits for the
    /// daemon's closed items to reach the store.
    static let arrivalLimit: Duration = .seconds(5)

    /// The closed items of this close: for each member name one new workspace
    /// item of that name (newest first), and the group's own record.
    private static func matches(names: [String], group id: String, after seen: Set<String>,
                                _ services: AppServices) -> (workspaces: [String], group: String?) {
        let fresh = DaemonClosedHistory.entries([.workspace], in: services).filter { !seen.contains($0.item.id) }
        var wanted = names
        var workspaces: [String] = []
        for entry in fresh where entry.item.group == nil {
            guard let index = wanted.firstIndex(of: entry.item.name ?? "") else { continue }
            wanted.remove(at: index)
            workspaces.append(entry.item.id)
        }
        return (workspaces, fresh.first { $0.item.group?.id == id }?.item.id)
    }

    /// Reopens what this close recorded once every member's item is in the
    /// store (or `arrivalLimit` passed): the workspaces oldest first, so each
    /// returns to its place, then the group's own record.
    private static func reopen(group id: String, names: [String], after seen: Set<String>, _ services: AppServices) async {
        let arrived: @MainActor @Sendable () -> Bool = { [weak services] in
            guard let services else { return true }
            return matches(names: names, group: id, after: seen, services).workspaces.count == names.count
        }
        if !arrived() { await ArrivalWait().until(arrived, limit: arrivalLimit) }
        let found = matches(names: names, group: id, after: seen, services)
        for itemID in found.workspaces.reversed() {
            if let entry = DaemonClosedHistory.entry(itemID, in: services) { DaemonClosedHistory.reopen(entry, services: services) }
        }
        if let groupItem = found.group, let entry = DaemonClosedHistory.groupEntry(id, in: services), entry.item.id == groupItem {
            DaemonClosedHistory.reopen(entry, services: services)
        }
    }

    static func closedToast(_ name: String) -> String {
        String(format: String(localized: "workspaceGroup.closedToast", defaultValue: "Closed the workspaces in “%@”",
                              table: "Handlers", bundle: .module), name)
    }
}

/// Waits until `condition` holds (an observation of the store) or `limit`
/// passes on a `DemandTimer`, whichever comes first; resumes once.
@MainActor
private final class ArrivalWait {
    private var continuation: CheckedContinuation<Void, Never>?
    private var watch: Task<Void, Never>?
    private let timer = DemandTimer(owner: "workspace-group-close-undo")

    func until(_ condition: @escaping @MainActor @Sendable () -> Bool, limit: Duration) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            // task-owner: this wait (cancelled in finish); event-driven (Observation)
            watch = Task { @MainActor [weak self] in
                for await done in ObservationStream(condition) where done { break }
                self?.finish()
            }
            timer.schedule(after: limit) { @MainActor [weak self] in self?.finish() }
        }
    }

    private func finish() {
        watch?.cancel()
        timer.cancel()
        continuation?.resume()
        continuation = nil
    }
}

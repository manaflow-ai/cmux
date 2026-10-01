import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Reopen Closed Workspace: the daemon's closed history (`closed.list`,
/// `closed.reopen`) recreates the newest closed workspace as a new one,
/// with its screens, tab order, names, and directories, then the app shows
/// it in the active window. Closed tabs and screens stay in the history for
/// their own verbs.
extension WorkspaceHandlers {
    /// How long the reopened workspace may take to reach the mirror before
    /// the action finishes without selecting it.
    static let reopenRevealTimeout: Duration = .seconds(5)

    static func reopenClosedWorkspace(_ context: AppActionContext) {
        let daemon = context.services.activeDaemon
        let store = daemon.store
        daemon.send("closed.reopen") { connection in
            let item = try await newestClosedWorkspace(in: connection.closedItems())
            let reopened = try await connection.reopenClosed(item.id)
            guard let workspace = await reopenedWorkspace(ResourceID(rawValue: reopened.workspaceID), in: store) else { return }
            await MainActor.run { _ = context.window(showing: workspace) }
        }
    }

    /// The newest closed workspace; tabs and screens closed after it are
    /// skipped, not consumed.
    nonisolated static func newestClosedWorkspace(in items: [DaemonConnection.ClosedItem]) throws -> DaemonConnection.ClosedItem {
        guard let item = items.first(where: { $0.kind == .workspace }) else {
            throw ActionFailure(message: RefusalStrings.noRecentlyClosedWorkspace)
        }
        return item
    }

    /// The mirror id of the workspace with resource id `id` once the store
    /// lists it, or nil after `timeout`.
    static func reopenedWorkspace(_ id: ResourceID, in store: DaemonStore,
                                  timeout: Duration = reopenRevealTimeout) async -> String? {
        if let found = store.workspaces.first(where: { $0.resourceID == id }) { return found.id }
        // concurrency-allow: Observations iteration ends on cancellation, so the group never waits past the deadline
        return await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { @MainActor in
                for await found in Observations({ store.workspaces.first(where: { $0.resourceID == id })?.id }) {
                    if let found { return found }
                }
                return nil
            }
            // wakeup-allow: one-shot deadline for the reopened workspace to reach the mirror
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
}

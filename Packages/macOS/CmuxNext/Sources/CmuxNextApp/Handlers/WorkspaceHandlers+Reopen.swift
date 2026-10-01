import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Reopen Closed Workspace: the daemon's closed history (`closed.list`,
/// `closed.reopen`) recreates the newest closed workspace as a new one
/// with its screens and tabs (each terminal a fresh shell), then the app
/// shows it in the active window. Closed tabs and screens stay in the
/// history for their own verbs.
extension WorkspaceHandlers {
    /// How long the reopened workspace may take to reach the mirror before
    /// the action finishes without selecting it.
    static let reopenRevealTimeout: Duration = .seconds(5)

    /// Attempts per press: another press or client can reopen the item
    /// between the list and the reopen, then the next newest is tried.
    static let reopenAttempts = 3

    static func reopenClosedWorkspace(_ context: AppActionContext) throws {
        _ = try context.requireConnection()
        let daemon = context.services.activeDaemon
        let store = daemon.store
        daemon.send("closed.reopen") { connection in
            do {
                let reopened = try await reopenNewestClosedWorkspace(on: connection)
                guard let workspace = await reopenedWorkspace(ResourceID(rawValue: reopened.workspaceID), in: store) else { return }
                await MainActor.run { _ = context.window(showing: workspace) }
            } catch let failure as ActionFailure {
                // The list is read off the main actor, so the refusal (and
                // its beep for keyboard and menu runs) comes after the run.
                await MainActor.run { context.refuse(failure.message) }
                throw failure
            }
        }
    }

    /// Lists the history and reopens its newest workspace, retrying with a
    /// fresh list when that item was reopened in the meantime.
    static func reopenNewestClosedWorkspace(on connection: DaemonConnection) async throws -> DaemonConnection.ReopenedItem {
        try await reopenNewestClosedWorkspace(list: { try await connection.closedItems() },
                                              reopen: { try await connection.reopenClosed($0) })
    }

    static func reopenNewestClosedWorkspace(list: () async throws -> [DaemonConnection.ClosedItem],
                                            reopen: (String) async throws -> DaemonConnection.ReopenedItem) async throws -> DaemonConnection.ReopenedItem {
        for attempt in 1...reopenAttempts {
            let item = try newestClosedWorkspace(in: try await list())
            do {
                return try await reopen(item.id)
            } catch DaemonError.command(_, _, let code) where code == "resource.not_found" && attempt < reopenAttempts {
                continue
            }
        }
        throw ActionFailure(message: RefusalStrings.noRecentlyClosedWorkspace)
    }

    /// The newest closed workspace; tabs and screens closed after it are
    /// skipped, not consumed.
    static func newestClosedWorkspace(in items: [DaemonConnection.ClosedItem]) throws -> DaemonConnection.ClosedItem {
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
            group.addTask { await appearance(of: id, in: store) }
            // wakeup-allow: one-shot deadline for the reopened workspace to reach the mirror
            group.addTask { _ = try? await Task.sleep(for: timeout); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    private static func appearance(of id: ResourceID, in store: DaemonStore) async -> String? {
        for await found in Observations({ store.workspaces.first(where: { $0.resourceID == id })?.id }) {
            if let found { return found }
        }
        return nil
    }
}

import CmuxNextDaemon
import Foundation
import os

/// Gives a shown workspace with no panes (for example after a hard daemon
/// kill) one terminal, so the window never shows an empty content area.
///
/// Process-wide so two windows showing the same workspace send one command.
/// A workspace stays claimed from the request until the store reports it
/// populated again, so re-applies of the stale tree (the create's delta has
/// not landed yet) never send a second command. A failed request releases
/// the claim; the next store change retries.
final class EmptyWorkspaceRepair {
    /// Creates the first terminal of `key` (`create-terminal`, which adds the
    /// first screen and pane). Returns the new surface. Tests replace it.
    var create: @MainActor (WorkspaceKey) async throws -> SurfaceID?
    /// Whether commands can run now. Tests replace it.
    var canCreate: @MainActor () -> Bool
    /// Workspaces with a request in flight or awaiting their populated delta.
    private var claimed: Set<String> = []
    /// Workspaces this app is creating and populating itself
    /// (create-workspace then create-terminal); never repaired meanwhile.
    private var populating: [WorkspaceKey: Int] = [:]
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.empty-workspace")

    init(daemon: DaemonService) {
        create = { [weak daemon] key in
            guard let connection = daemon?.connection else { throw DaemonError.notConnected }
            return try await connection.createTerminal(in: key, cwd: NSHomeDirectory()).surface
        }
        canCreate = { [weak daemon] in
            guard let daemon, daemon.store.isLoaded else { return false }
            if case .connected = daemon.store.connectionState { return true }
            return false
        }
    }

    /// Checks `workspace` after a store change. When it has no pane, sends one
    /// create-terminal and calls `created` with the new surface.
    func check(_ workspace: WorkspaceModel, created: @escaping @MainActor (SurfaceID) -> Void) {
        guard workspace.screens.allSatisfy(\.panes.isEmpty) else {
            claimed.remove(workspace.id)
            return
        }
        guard let key = workspace.key, populating[key] == nil, !claimed.contains(workspace.id), canCreate() else { return }
        claimed.insert(workspace.id)
        let id = workspace.id
        logger.info("workspace \(id, privacy: .public) has no pane; creating a terminal")
        let create = create
        Task {
            do {
                if let surface = try await create(key) { created(surface) }
            } catch {
                claimed.remove(id)
                logger.error("empty workspace repair failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Marks `key` as being populated by this app for the duration of `body`
    /// (a new workspace is empty between create-workspace and create-terminal).
    func populating<T>(_ key: WorkspaceKey, _ body: () async throws -> T) async rethrows -> T {
        populating[key, default: 0] += 1
        defer {
            populating[key, default: 1] -= 1
            if populating[key] == 0 { populating[key] = nil }
        }
        return try await body()
    }
}

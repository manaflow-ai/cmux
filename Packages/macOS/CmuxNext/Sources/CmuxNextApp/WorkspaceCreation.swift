import CmuxNextDaemon
import Foundation
import os

/// Creates a workspace and its first terminal with two daemon requests
/// (create-workspace, then create-terminal), and never leaves a
/// half-created workspace: when the terminal step fails, the new workspace
/// is closed again and the terminal step's error is the one reported. The
/// daemon's single atomic `workspace.create` cannot take a caller key, cwd,
/// env, terminal id or keep yet (plans: the workspace.create extension).
enum WorkspaceCreation {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.workspace-create")

    static func withTerminal<T>(
        createWorkspace: () async throws -> WorkspaceKey,
        createTerminal: (WorkspaceKey) async throws -> T,
        closeWorkspace: (WorkspaceKey) async throws -> Void
    ) async throws -> T {
        let key = try await createWorkspace()
        do {
            return try await createTerminal(key)
        } catch {
            do {
                try await closeWorkspace(key)
            } catch let closeError {
                // The terminal failure stays the one error the user sees.
                logger.error("closing a half-created workspace failed: \(String(describing: closeError), privacy: .public)")
            }
            throw error
        }
    }

    /// Creates workspace `key` (named `name`) with its first terminal
    /// (`terminal`) on `connection`, owned by `repair` while it runs: a
    /// failure closes the workspace (its terminals with it) and the repair
    /// never fills it.
    @MainActor
    static func create<T>(
        _ key: WorkspaceKey,
        name: String?,
        on connection: DaemonConnection,
        repair: EmptyWorkspaceRepair,
        terminal: (WorkspaceKey) async throws -> T
    ) async throws -> T {
        try await repair.populating(key) {
            try await withTerminal(
                createWorkspace: { try await connection.createWorkspace(name: name, key: key).key },
                createTerminal: terminal,
                closeWorkspace: { try await WorkspaceClose.close($0, terminals: [], on: connection) }
            )
        }
    }

    /// Creates workspace `key` and its first tab from `firstTab`, which gets
    /// the created workspace (its handle, for commands that take one), owned
    /// by `repair` like ``create(_:name:on:repair:terminal:)``: a failure
    /// closes the workspace.
    @MainActor
    static func createWithFirstTab<T>(
        _ key: WorkspaceKey,
        name: String?,
        on connection: DaemonConnection,
        repair: EmptyWorkspaceRepair,
        firstTab: (WorkspaceMutationResult) async throws -> T
    ) async throws -> T {
        try await repair.populating(key) {
            var created: WorkspaceMutationResult?
            return try await withTerminal(
                createWorkspace: {
                    let result = try await connection.createWorkspace(name: name, key: key)
                    created = result
                    return result.key
                },
                createTerminal: { _ in
                    guard let created else { throw DaemonError.notConnected }
                    return try await firstTab(created)
                },
                closeWorkspace: { try await WorkspaceClose.close($0, terminals: [], on: connection) }
            )
        }
    }

    /// A person's new workspace on the New Tab page (`opensNewTabPage`),
    /// starting in `cwd`; nil when `spawn` gets a terminal instead (it runs a
    /// command, or `daemon` cannot host the page).
    @MainActor
    static func newTabPage(_ spawn: WorkspaceSpawn, _ key: WorkspaceKey, cwd: String?, on daemon: DaemonService,
                           repair: EmptyWorkspaceRepair, tabs: AgentTabStore) async throws -> String? {
        guard spawn.opensNewTabPage, spawn.command == nil, tabs.canHost(on: daemon), let connection = daemon.connection else { return nil }
        return try await createWithFirstTab(key, name: spawn.name, on: connection, repair: repair) { created in
            _ = try await tabs.openFirstPage(workspace: created.workspace, cwd: cwd, on: daemon)
            return created.key.rawValue
        }
    }
}

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
}

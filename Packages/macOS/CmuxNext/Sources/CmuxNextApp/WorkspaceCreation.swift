import CmuxNextDaemon
import Foundation

/// Creates a workspace and its first terminal with two daemon requests
/// (create-workspace, then create-terminal). The daemon's single atomic
/// `workspace.create` cannot take a caller key, cwd, env, terminal id or
/// keep yet (plans: workspace.create extension).
enum WorkspaceCreation {
    static func withTerminal(
        createWorkspace: () async throws -> WorkspaceKey,
        createTerminal: (WorkspaceKey) async throws -> Void,
        closeWorkspace: (WorkspaceKey) async throws -> Void
    ) async throws -> WorkspaceKey {
        let key = try await createWorkspace()
        try await createTerminal(key)
        return key
    }
}

import CmuxNextDaemon
import Foundation

/// How Reopen Closed Tab brings a terminal tab back. Closing a tab only
/// detaches its terminal; the daemon ends it after the reap grace period
/// (`terminal-reap-v1`, default 30 s). Within that window `project` shows
/// the same live terminal again (scrollback and running process intact);
/// once it ended, `spawn` starts a new shell in the saved directory. Tests
/// replace both.
struct ClosedTerminalRestorer {
    struct Spawn {
        var pane: PaneID
        var cwd: String?
        var workspace: WorkspaceKey?
        var index: Int
    }

    /// Whether commands can run now (a connected daemon).
    var isAvailable: @MainActor () -> Bool
    /// Adds a tab for terminal `term_…` at the index in the pane; returns
    /// the new tab's resource id. Throws when the terminal is gone.
    var project: @MainActor (ResourceID, PaneResourcePath, Int) async throws -> ResourceID
    /// New terminal tab moved to the index; returns its surface.
    var spawn: @MainActor (Spawn) async throws -> SurfaceID

    /// The real daemon path for `daemon`'s connection at call time.
    static func live(_ daemon: DaemonService) -> ClosedTerminalRestorer {
        ClosedTerminalRestorer(
            isAvailable: { [weak daemon] in daemon?.connection != nil },
            project: { [weak daemon] terminal, path, index in
                guard let connection = daemon?.connection else { throw DaemonError.notConnected }
                return try await connection.projectTerminal(terminal, into: path, index: index).id
            },
            spawn: { [weak daemon] spawn in
                guard let connection = daemon?.connection else { throw DaemonError.notConnected }
                let created = try await connection.newTab(in: spawn.pane, options: SpawnOptions(cwd: spawn.cwd, workspace: spawn.workspace))
                _ = try await connection.moveTab(created.surface, to: spawn.pane, index: spawn.index)
                return created.surface
            })
    }
}

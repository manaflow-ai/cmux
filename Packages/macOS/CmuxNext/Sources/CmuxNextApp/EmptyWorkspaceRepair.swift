import CmuxNextDaemon
import Foundation

/// Gives a shown workspace with no panes (for example after a hard daemon
/// kill) one terminal, so the window never shows an empty content area.
final class EmptyWorkspaceRepair {
    /// Creates the first terminal of `key` (`create-terminal`, which adds the
    /// first screen and pane). Returns the new surface. Tests replace it.
    var create: @MainActor (WorkspaceKey) async throws -> SurfaceID?
    /// Whether commands can run now. Tests replace it.
    var canCreate: @MainActor () -> Bool

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
}

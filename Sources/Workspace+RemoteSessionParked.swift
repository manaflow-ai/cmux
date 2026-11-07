import CmuxCore
import Foundation

/// What the workspace knows about a remote session that gave up
/// (https://github.com/manaflow-ai/cmux/issues/12813).
@MainActor
extension Workspace {
    /// Whether the session owner stopped recovering on its own. Terminal
    /// attach attempts are not progress while this holds, so they must not
    /// repaint the workspace as connecting.
    var remoteControllerIsParked: Bool {
        remoteControllerConnectionState == .error || remoteControllerConnectionState == .suspended
    }

    /// Whether no controller or transition can make this remote session ready
    /// without an explicit Reconnect. This also covers a deliberate
    /// Disconnect as soon as its disconnected state is published.
    var remoteSessionIsWaitingForReconnect: Bool {
        guard remoteSessionController == nil else {
            return false
        }
        // A deferred first connection can also be disconnected. Only the
        // explicit Disconnect action terminates waiting attaches, including
        // those that arrive while its transport cleanup is still running.
        if remoteConnectionWasDisconnected, remoteConfiguration != nil {
            return true
        }
        guard remoteSessionTransitionTask == nil else {
            return false
        }
        return remoteControllerIsParked ||
            remoteConnectionState == .error
    }

    /// The user-facing reason when no remote session controller exists and
    /// none will be created until the user reconnects; `nil` while one exists
    /// or a transition that may still create one is in flight.
    ///
    /// A parked controller reports its own reason to the attaches waiting on
    /// it. Without a controller there is nobody to do that, so
    /// `workspace.remote.pty_bridge` asks the workspace instead of waiting out
    /// its controller deadline.
    var remoteSessionParkedDetailWithoutController: String? {
        // A rejected ControlMaster adoption fails `configureRemoteConnection`
        // before any configuration or controller state is recorded; only the
        // presented state says `.error`. Without a controller, that is just
        // as final as a parked controller state.
        guard remoteSessionIsWaitingForReconnect else {
            return nil
        }
        for candidate in [remoteControllerConnectionDetail, remoteConnectionDetail] {
            let detail = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty { return detail }
        }
        return String(
            localized: "remoteSession.parked.notActive",
            defaultValue: "The SSH connection is not active. Use Reconnect to try again."
        )
    }

    /// The reason published when a reconnect could not release the previous
    /// connection's remote state and therefore never started a replacement.
    var remoteSessionCleanupBlockedDetail: String {
        String(
            format: String(
                localized: "remoteSession.parked.cleanupBlocked",
                defaultValue: "cmux could not clean up the previous SSH connection to %@. Check that the host is reachable, then use Reconnect to try again."
            ),
            remoteDisplayTarget ?? ""
        )
    }
}

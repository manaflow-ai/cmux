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

    /// The user-facing reason when no remote session controller exists and
    /// none will be created until the user reconnects; `nil` while one exists
    /// or a transition that may still create one is in flight.
    ///
    /// A parked controller reports its own reason to the attaches waiting on
    /// it. Without a controller there is nobody to do that, so
    /// `workspace.remote.pty_bridge` asks the workspace instead of waiting out
    /// its controller deadline.
    var remoteSessionParkedDetailWithoutController: String? {
        guard remoteConfiguration != nil,
              remoteSessionController == nil,
              remoteSessionTransitionTask == nil,
              remoteControllerIsParked else {
            return nil
        }
        let detail = remoteControllerConnectionDetail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail, !detail.isEmpty { return detail }
        return String(
            format: String(
                localized: "remoteSession.parked.notActive",
                defaultValue: "The SSH connection to %@ is not active. Use Reconnect to try again."
            ),
            remoteDisplayTarget ?? ""
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

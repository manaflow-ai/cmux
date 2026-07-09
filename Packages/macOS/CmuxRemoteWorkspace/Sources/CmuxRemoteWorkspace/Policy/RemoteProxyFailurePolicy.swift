public import CmuxCore
import Foundation

/// Decides whether a remote workspace should preserve a daemon-proxy failure
/// rather than tearing the connection down, because a live SSH terminal session
/// is still usable on top of it.
///
/// Pure value/decision helper extracted from the legacy
/// `Workspace.preservesProxyFailureWhileSSHTerminalIsAlive` computed property:
/// the workspace supplies the three live inputs (its remote transport, its
/// active remote terminal session count, and its configured terminal startup
/// command) and this type returns the boolean verdict. Holding the rule here
/// keeps it unit-testable without an app target and beside the other remote
/// status/effective-state decisions in this package.
public struct RemoteProxyFailurePolicy: Sendable {
    /// Creates the policy.
    public init() {}

    /// Whether a proxy failure should be preserved while an SSH terminal is
    /// alive: true only for the `.ssh` transport with at least one active
    /// remote terminal session and a non-empty configured startup command.
    public func preservesProxyFailureWhileSSHTerminalIsAlive(
        transport: WorkspaceRemoteTransport?,
        activeSessionCount: Int,
        startupCommand: String?
    ) -> Bool {
        transport == .ssh
            && activeSessionCount > 0
            && startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

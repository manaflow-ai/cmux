internal import CmuxRemoteDaemon
internal import Foundation

extension RemotePTYBridgeServer.Session {
    /// Maps a daemon attach failure onto the app-resolved user-facing string;
    /// the matching rules (substring markers, in this order) are wire-pinned
    /// legacy behavior.
    func userFacingBridgeErrorMessage(_ error: any Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if lowered.contains("missing required capability") ||
            lowered.contains("pty.session") ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYWriteNotificationCapability) ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYResizeNotificationCapability) {
            return strings.missingPersistentPTYCapability
        }
        if Self.bridgeErrorCode(for: error) == "pty_session_not_found" {
            return strings.sessionEnded
        }
        if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
            return strings.inputBackedUp
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return strings.daemonTimeout
        }
        // Surface the daemon's PTY-allocation diagnostic (it names the failing
        // device and the devpts/ptmxmode cause) instead of collapsing it into a
        // generic message. Key off the daemon's stable marker only, so an
        // unrelated error that merely mentions a device path is not leaked.
        // See https://github.com/manaflow-ai/cmux/issues/5185.
        if lowered.contains("could not allocate a remote pty") {
            return strings.allocationDiagnostic(message)
        }
        return strings.attachFailed
    }

    static func bridgeErrorCode(for error: any Error) -> String? {
        let lowered = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if lowered.contains("pty_session_not_found") ||
            (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
            (lowered.contains("persistent pty session") && lowered.contains("not running")) {
            return "pty_session_not_found"
        }
        return nil
    }
}

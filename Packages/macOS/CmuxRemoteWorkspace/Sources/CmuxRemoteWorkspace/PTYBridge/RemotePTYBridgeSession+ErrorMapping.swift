internal import CmuxRemoteDaemon
internal import CmuxFoundation
internal import Foundation

extension RemotePTYBridgeServer.Session {
    /// Maps a daemon attach failure onto the app-resolved user-facing string.
    /// Marker matching remains the legacy display fallback; the machine code is
    /// resolved independently and is never inferred by the CLI from this text.
    func userFacingBridgeErrorMessage(_ error: any Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return userFacingBridgeErrorMessage(
            message: message,
            code: Self.bridgeErrorCode(for: error)
        )
    }

    /// Maps a bridge event's text and optional wire code without manufacturing
    /// an NSError solely to preserve the status-line contract.
    func userFacingBridgeErrorMessage(message: String, code: String?) -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return strings.attachFailed }
        let lowered = message.lowercased()
        if lowered.contains("missing required capability") ||
            lowered.contains("missing required capabilities") ||
            lowered.contains("does not support persistent ssh pty sessions") ||
            lowered.contains("pty.session") ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYWriteNotificationCapability) ||
            lowered.contains(RemoteDaemonRPCClient.requiredPTYResizeNotificationCapability) ||
            lowered.contains("method_not_found") ||
            lowered.contains("unrecognized_method") {
            return strings.missingPersistentPTYCapability
        }
        if lowered.contains("pty_session_not_found") ||
            (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
            (lowered.contains("persistent pty session") && lowered.contains("not running")) ||
            RemotePTYErrorCode.normalized(code) == RemotePTYErrorCode.sessionNotFound.rawValue {
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
        guard let code = RemotePTYErrorCode.normalized(code) else {
            return strings.attachFailed
        }
        switch code {
        case RemotePTYErrorCode.capabilityMissing.rawValue:
            return strings.missingPersistentPTYCapability
        case RemotePTYErrorCode.sessionNotFound.rawValue:
            return strings.sessionEnded
        case RemotePTYErrorCode.inputQueueFull.rawValue:
            return strings.inputBackedUp
        case RemotePTYErrorCode.timeout.rawValue:
            return strings.daemonTimeout
        default:
            break
        }
        return strings.attachFailed
    }

    static func bridgeErrorCode(for error: any Error) -> String {
        RemotePTYErrorCode.code(for: error)
    }
}

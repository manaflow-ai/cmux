import CmuxFoundation
import Foundation

extension TerminalController {
    /// Returns the machine-readable code placed on v2 remote-PTY failures.
    nonisolated func v2RemotePTYErrorCode(_ error: any Error) -> String {
        RemotePTYErrorCode.code(for: error)
    }

    /// Resolves the app-bundle human message for a remote-PTY failure.
    nonisolated func v2RemotePTYUserFacingErrorMessage(_ error: any Error) -> String {
        v2RemotePTYUserFacingErrorMessage(
            error.localizedDescription,
            code: v2RemotePTYErrorCode(error)
        )
    }

    /// Maps legacy remote-PTY text for older daemon/app pairs and display.
    nonisolated func v2RemotePTYUserFacingErrorMessage(_ message: String) -> String {
        v2RemotePTYUserFacingErrorMessage(message, code: nil)
    }

    private nonisolated func v2RemotePTYUserFacingErrorMessage(
        _ message: String,
        code: String?
    ) -> String {
        // Keep these established English wire messages stable for older CLIs;
        // new clients must use the machine code instead of parsing this text.
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "remote PTY operation failed" }
        let lowered = trimmed.lowercased()

        // Preserve the established marker precedence for deployed clients and
        // localized display strings.
        if lowered.contains("missing required capability") ||
            lowered.contains("missing required capabilities") ||
            lowered.contains("does not support persistent ssh pty sessions") ||
            lowered.contains("pty.session") ||
            lowered.contains("method_not_found") ||
            lowered.contains("unrecognized_method") {
            return "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
        }
        if lowered.contains("pty_session_not_found") ||
            (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
            (lowered.contains("persistent pty session") && lowered.contains("not running")) {
            return "persistent SSH PTY session is no longer running"
        }
        if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
            return "remote PTY input is temporarily backed up"
        }
        if lowered.contains("remote connection is not active") {
            return "remote connection is not active"
        }
        if lowered.contains("remote daemon is not ready") || lowered.contains("remote daemon tunnel is not ready") {
            return "remote daemon is not ready"
        }
        if lowered.contains("missing workspace_id in ssh pty session list response") {
            return "missing workspace_id in SSH PTY session list response"
        }
        if lowered.contains("missing session_id in ssh pty session list response") {
            return "missing session_id in SSH PTY session list response"
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return "remote daemon did not respond in time"
        }

        // A structured response can carry a useful category while retaining a
        // transport-neutral message (for example, a daemon context deadline).
        guard let code = RemotePTYErrorCode.normalized(code) else {
            return "remote PTY operation failed"
        }
        switch code {
        case RemotePTYErrorCode.capabilityMissing.rawValue:
            return "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
        case RemotePTYErrorCode.sessionNotFound.rawValue:
            return "persistent SSH PTY session is no longer running"
        case RemotePTYErrorCode.inputQueueFull.rawValue:
            return "remote PTY input is temporarily backed up"
        case RemotePTYErrorCode.connectionInactive.rawValue:
            return "remote connection is not active"
        case RemotePTYErrorCode.timeout.rawValue:
            return "remote daemon did not respond in time"
        default:
            return "remote PTY operation failed"
        }
    }
}

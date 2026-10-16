import CmuxFoundation
import Foundation

extension CMUXCLI {
    /// Classifies a failed `workspace.remote.pty_bridge` request. Prefers the
    /// structured v2 error code over description matching so a message-format
    /// change cannot silently turn a retryable failure fatal, or a terminal
    /// one retryable.
    func sshPTYBridgeEstablishmentExitCode(_ error: any Error) -> SSHPTYAttachExitCode {
        if let cliError = error as? CLIError, let code = cliError.v2Code {
            return SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: code,
                message: cliError.message
            )
        }
        return SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(String(describing: error))
    }

    /// Whether the app answered that the remote session is parked: it gave
    /// up, only an explicit Reconnect resumes it, and the attach must stop
    /// (https://github.com/manaflow-ai/cmux/issues/12813).
    func sshPTYBridgeErrorIsParkedSession(_ error: any Error) -> Bool {
        sshPTYParkedSessionDetail(error) != nil
    }

    /// The app-localized reason and next step carried by a parked-session
    /// reply. It is already user-facing, so it is shown verbatim rather than
    /// mapped through the phrase matching below, which would turn a detail
    /// that mentions a timeout into "remote daemon did not respond in time".
    func sshPTYParkedSessionDetail(_ error: any Error) -> String? {
        guard let cliError = error as? CLIError,
              cliError.isStructuredProtocolResponse,
              let code = cliError.v2Code,
              code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == SSHPTYAttachExitCode.sessionParkedErrorCode else {
            return nil
        }
        // `CLIError.message` is the formatted "<code>: <message>" header.
        var detail = cliError.message
        if detail.hasPrefix("\(code):") { detail.removeFirst(code.count + 1) }
        detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? nil : detail
    }

    func userFacingRemotePTYErrorMessage(_ value: Any?) -> String {
        if let error = value as? Error {
            if let parkedDetail = sshPTYParkedSessionDetail(error) { return parkedDetail }
            return userFacingRemotePTYErrorMessage(String(describing: error))
        }
        return userFacingRemotePTYErrorMessage(debugString(value) ?? "unknown error")
    }

    func userFacingRemotePTYErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "remote PTY operation failed" }
        let lowered = trimmed.lowercased()
        if lowered.contains("missing required capability") ||
            lowered.contains("pty.session") ||
            lowered.contains("pty.write.notification") ||
            lowered.contains("pty.resize.notification") ||
            lowered.contains("method_not_found") {
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
        // Surface the daemon's PTY-allocation diagnostic verbatim (it names the
        // failing device and the devpts/ptmxmode cause) instead of collapsing it
        // into a generic message. Key off the daemon's stable marker only, so an
        // unrelated error that merely mentions a device path is not leaked. The
        // peer branches in this CLI helper return plain English, so this branch
        // does too. See issue #5185.
        if lowered.contains("could not allocate a remote pty") {
            return trimmed
        }
        return "remote PTY operation failed"
    }
}

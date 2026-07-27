import Foundation

extension CMUXCLI {
    func userFacingRemotePTYErrorMessage(_ value: Any?) -> String {
        if let error = value as? Error {
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

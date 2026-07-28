internal import Foundation

/// Classifies foreground SSH authentication failures without hiding interactive
/// prompts or retrying permanent authentication and configuration errors.
///
/// OpenSSH uses status 255 for both transport outages and permanent failures.
/// The persistent PTY wrappers therefore need stderr context before deciding
/// whether an initial authentication attempt belongs in their reconnect loop.
public struct SSHForegroundAuthenticationRetryPolicy: Sendable {
    /// Maximum consecutive transport failures before foreground auth surfaces the outage.
    public let maximumConsecutiveTransientFailures = 20
    private let transientFailurePattern: String
    private let permanentFailurePattern: String

    /// Creates the policy used by cmux's foreground SSH authentication wrappers.
    public init() {
        transientFailurePattern = [
            "network is unreachable",
            "no route to host",
            "operation timed out",
            "connection timed out",
            "temporary failure in name resolution",
            "connection closed by unknown port 65535",
            "connection to unknown port 65535: broken pipe",
        ].joined(separator: "|")
        permanentFailurePattern = [
            "permission denied",
            "host key verification failed",
            "remote host identification has changed",
            "authentication failed",
            "too many authentication failures",
            "bad configuration option",
            "no matching host key type found",
            "no matching cipher found",
            "no matching mac found",
            "no matching key exchange method found",
            "could not resolve hostname",
            "name or service not known",
            "nodename nor servname provided",
        ].joined(separator: "|")
    }

    /// Wraps a zsh command so transient transport failures exit 254 while every
    /// other exit status is preserved.
    ///
    /// Stderr is copied through a private FIFO and `tee`, keeping password,
    /// host-key, and proxy prompts live on the terminal while retaining enough
    /// diagnostics to distinguish a boot-time outage from status-255 auth or
    /// configuration failures. Temporary diagnostics are removed on normal
    /// completion and signals.
    ///
    /// - Parameter command: Shell command to execute under zsh.
    /// - Returns: A zsh command suitable for embedding in a startup script.
    public func classifyingTransientFailure(in command: String) -> String {
        let nestedCommand = "/bin/zsh -fc \(shellQuote(command))"
        let script = [
            "umask 077",
            "cmux_ssh_auth_capture_log=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-auth.XXXXXX\") || exit 255",
            "cmux_ssh_auth_capture_fifo=\"$cmux_ssh_auth_capture_log.fifo\"",
            "cmux_ssh_auth_capture_tee_pid=",
            "cmux_ssh_auth_capture_cleanup() {",
            "  if [ -n \"${cmux_ssh_auth_capture_tee_pid:-}\" ]; then",
            "    /bin/kill \"$cmux_ssh_auth_capture_tee_pid\" >/dev/null 2>&1 || true",
            "    wait \"$cmux_ssh_auth_capture_tee_pid\" 2>/dev/null || true",
            "  fi",
            "  /bin/rm -f -- \"$cmux_ssh_auth_capture_fifo\" \"$cmux_ssh_auth_capture_log\" 2>/dev/null || true",
            "}",
            "cmux_ssh_auth_capture_signal_exit() {",
            "  cmux_ssh_auth_capture_signal_status=\"$1\"",
            "  trap - EXIT HUP INT TERM",
            "  cmux_ssh_auth_capture_cleanup",
            "  exit \"$cmux_ssh_auth_capture_signal_status\"",
            "}",
            "trap 'cmux_ssh_auth_capture_cleanup' EXIT",
            "trap 'cmux_ssh_auth_capture_signal_exit 129' HUP",
            "trap 'cmux_ssh_auth_capture_signal_exit 130' INT",
            "trap 'cmux_ssh_auth_capture_signal_exit 143' TERM",
            "if ! /usr/bin/mkfifo \"$cmux_ssh_auth_capture_fifo\"; then exit 255; fi",
            "/usr/bin/tee \"$cmux_ssh_auth_capture_log\" < \"$cmux_ssh_auth_capture_fifo\" >&2 &",
            "cmux_ssh_auth_capture_tee_pid=$!",
            "\(nestedCommand) 2> \"$cmux_ssh_auth_capture_fifo\"",
            "cmux_ssh_auth_capture_status=$?",
            "wait \"$cmux_ssh_auth_capture_tee_pid\" 2>/dev/null || true",
            "cmux_ssh_auth_capture_tee_pid=",
            "if [ \"$cmux_ssh_auth_capture_status\" -eq 255 ] \\",
            "  && ! LC_ALL=C /usr/bin/grep -Eiq \(shellQuote(permanentFailurePattern)) \"$cmux_ssh_auth_capture_log\" \\",
            "  && LC_ALL=C /usr/bin/grep -Eiq \(shellQuote(transientFailurePattern)) \"$cmux_ssh_auth_capture_log\"; then",
            "  cmux_ssh_auth_capture_status=254",
            "fi",
            "trap - EXIT HUP INT TERM",
            "cmux_ssh_auth_capture_cleanup",
            "exit \"$cmux_ssh_auth_capture_status\"",
        ].joined(separator: "\n")
        return "/bin/zsh -fc \(shellQuote(script))"
    }

    private func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

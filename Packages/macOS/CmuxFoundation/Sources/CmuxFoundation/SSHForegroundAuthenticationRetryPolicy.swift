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
            "name or service not known",
            "nodename nor servname provided",
        ].joined(separator: "|")
    }

    /// Wraps a zsh command so transient transport failures exit 254 while every
    /// other exit status is preserved.
    ///
    /// Stderr is copied live through private FIFOs while an incremental
    /// classifier retains only a bounded result marker. This keeps password,
    /// host-key, and proxy prompts visible without allowing a noisy remote
    /// command to grow a diagnostic file. Temporary state is removed on normal
    /// completion and signals.
    ///
    /// - Parameter command: Shell command to execute under zsh.
    /// - Returns: A zsh command suitable for embedding in a startup script.
    public func classifyingTransientFailure(in command: String) -> String {
        let nestedCommand = "/bin/zsh -fc \(shellQuote(command))"
        let classifierProgram = """
        {
          cmux_ssh_auth_line = tolower($0)
          if (cmux_ssh_auth_line ~ cmux_ssh_auth_permanent_pattern) {
            print "permanent" > cmux_ssh_auth_classification
            close(cmux_ssh_auth_classification)
            cmux_ssh_auth_saw_permanent = 1
          } else if (!cmux_ssh_auth_saw_permanent && cmux_ssh_auth_line ~ cmux_ssh_auth_transient_pattern) {
            print "transient" > cmux_ssh_auth_classification
            close(cmux_ssh_auth_classification)
          }
        }
        """
        let script = [
            "umask 077",
            "cmux_ssh_auth_capture_state=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-auth.XXXXXX\") || exit 255",
            "cmux_ssh_auth_capture_fifo=\"$cmux_ssh_auth_capture_state.capture.fifo\"",
            "cmux_ssh_auth_classifier_fifo=\"$cmux_ssh_auth_capture_state.classifier.fifo\"",
            "cmux_ssh_auth_capture_tee_pid=",
            "cmux_ssh_auth_classifier_pid=",
            "cmux_ssh_auth_capture_cleanup() {",
            "  for cmux_ssh_auth_capture_pid in \"${cmux_ssh_auth_capture_tee_pid:-}\" \"${cmux_ssh_auth_classifier_pid:-}\"; do",
            "    if [ -n \"$cmux_ssh_auth_capture_pid\" ]; then",
            "      /bin/kill \"$cmux_ssh_auth_capture_pid\" >/dev/null 2>&1 || true",
            "      wait \"$cmux_ssh_auth_capture_pid\" 2>/dev/null || true",
            "    fi",
            "  done",
            "  /bin/rm -f -- \"$cmux_ssh_auth_capture_fifo\" \"$cmux_ssh_auth_classifier_fifo\" \"$cmux_ssh_auth_capture_state\" 2>/dev/null || true",
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
            "if ! /usr/bin/mkfifo \"$cmux_ssh_auth_capture_fifo\" \"$cmux_ssh_auth_classifier_fifo\"; then exit 255; fi",
            "LC_ALL=C /usr/bin/awk -v cmux_ssh_auth_classification=\"$cmux_ssh_auth_capture_state\" -v cmux_ssh_auth_transient_pattern=\(shellQuote(transientFailurePattern)) -v cmux_ssh_auth_permanent_pattern=\(shellQuote(permanentFailurePattern)) \(shellQuote(classifierProgram)) < \"$cmux_ssh_auth_classifier_fifo\" &",
            "cmux_ssh_auth_classifier_pid=$!",
            "/usr/bin/tee \"$cmux_ssh_auth_classifier_fifo\" < \"$cmux_ssh_auth_capture_fifo\" >&2 &",
            "cmux_ssh_auth_capture_tee_pid=$!",
            "\(nestedCommand) 2> \"$cmux_ssh_auth_capture_fifo\"",
            "cmux_ssh_auth_capture_status=$?",
            "wait \"$cmux_ssh_auth_capture_tee_pid\" 2>/dev/null || true",
            "cmux_ssh_auth_capture_tee_pid=",
            "wait \"$cmux_ssh_auth_classifier_pid\" 2>/dev/null || true",
            "cmux_ssh_auth_classifier_pid=",
            "if [ \"$cmux_ssh_auth_capture_status\" -eq 255 ] \\",
            "  && [ \"$(/bin/cat -- \"$cmux_ssh_auth_capture_state\" 2>/dev/null || true)\" = transient ]; then",
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

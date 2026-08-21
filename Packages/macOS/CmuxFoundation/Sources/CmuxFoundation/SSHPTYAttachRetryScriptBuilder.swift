internal import Foundation

/// Builds the shared shell retry state machine for persistent SSH PTY attachment.
///
/// Both app-restored terminals and CLI-created attach commands use this builder
/// so retry limits, backoff, authentication phases, and exit-status handling
/// cannot drift between entrypoints.
public struct SSHPTYAttachRetryScriptBuilder: Sendable {
    /// Creates a persistent SSH PTY retry script builder.
    public init() {}

    /// Builds shell lines that retry PTY attachment and optional foreground authentication.
    ///
    /// The surrounding script supplies `cmux_ssh_attach_foreground_auth` when
    /// `reauthenticates` is true and installs `cmux_ssh_attach_signal_exit`
    /// before these lines execute.
    ///
    /// - Parameters:
    ///   - command: Shell command that performs one PTY attachment attempt.
    ///   - reauthenticates: Whether status 255 requires foreground authentication before reattaching.
    /// - Returns: macOS `/bin/sh` lines implementing the shared retry state machine.
    public func lines(command: String, reauthenticates: Bool) -> [String] {
        let reauthenticate = reauthenticates ? "cmux_ssh_attach_reauth_required=1" : ":"
        let authPolicy = SSHForegroundAuthenticationRetryPolicy()
        let authenticationResult = authPolicy.persistentAuthenticationResultShellLine(
            variablePrefix: "cmux_ssh_attach",
            terminalFailureCommand: "exit \"$cmux_ssh_attach_status\""
        )
        let backoffBuilder = SSHRetryBackoffScriptBuilder(context: .attach)
        let initialReauthentication = reauthenticates ? 1 : 0
        let noProgressPolicy = SSHPTYAttachExitCode.noProgressShellPolicy()
        let reattachingFormat = String(
            localized: "cli.sshPtyAttach.bridgeClosedReattaching",
            defaultValue: "[cmux] remote PTY bridge closed; reattaching (attempt %s/%s)."
        ).remoteCommandShellQuoted
        let retryWithoutReauthenticationStatus =
            SSHPTYAttachExitCode.retryableWithoutReauthentication.rawValue
        let noProgressStatus = SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue
        let sessionRunningStatus = SSHPTYAttachExitCode.bridgeClosedSessionRunning.rawValue
        let transientStatus = SSHPTYAttachExitCode.retryableTransient.rawValue
        let terminalModeReset = SSHTerminalModeResetSequence().shellPrintfFormat.remoteCommandShellQuoted
        var lines = [
            "cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-}\"",
            "case \"$cmux_ssh_attach_reconnect_limit\" in '') cmux_ssh_attach_reconnect_limit='∞'; cmux_ssh_attach_reconnect_unbounded=1 ;; *[!0-9]*) cmux_ssh_attach_reconnect_limit=20; cmux_ssh_attach_reconnect_unbounded=0 ;; *) cmux_ssh_attach_reconnect_unbounded=0 ;; esac",
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_delay=2 ;; esac",
            "cmux_ssh_attach_reconnect_max_delay=\"${CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS:-30}\"",
            "case \"$cmux_ssh_attach_reconnect_max_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_max_delay=30 ;; esac",
            "if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi",
            "cmux_ssh_attach_reconnect_initial_delay=\"$cmux_ssh_attach_reconnect_delay\"",
        ]
        lines.append(contentsOf: noProgressPolicy.configurationLines)
        lines.append(contentsOf: [
            "cmux_ssh_attach_no_progress_retry=0",
            "cmux_ssh_attach_retry=0",
            "cmux_ssh_attach_auth_retry=0",
            "cmux_ssh_attach_auth_retry_limit=\(authPolicy.maximumConsecutiveTransientFailures)",
            "cmux_ssh_attach_auth_succeeded=0",
            "cmux_ssh_attach_reauth_required=\(initialReauthentication)",
            "cmux_ssh_attach_auth_launching=0",
        ])
        lines.append(contentsOf: backoffBuilder.stateInitializationLines)
        lines.append(contentsOf: [
            "while :; do",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 1 ]; then",
            "    cmux_ssh_attach_auth_launching=1",
            "    ( cmux_ssh_attach_foreground_auth ) <&0 &",
            "    cmux_ssh_attach_auth_pid=$!",
            "    cmux_ssh_attach_auth_launching=0",
            "    if [ -n \"${cmux_ssh_attach_pending_signal:-}\" ]; then cmux_ssh_attach_signal_exit \"$cmux_ssh_attach_pending_signal\" \"${cmux_ssh_attach_pending_signal_name:-TERM}\"; fi",
            "    wait \"$cmux_ssh_attach_auth_pid\"; cmux_ssh_attach_status=$?; cmux_ssh_attach_auth_pid=",
            "    \(authenticationResult)",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 0 ]; then",
            "  if [ \"$cmux_ssh_attach_reconnect_unbounded\" -eq 1 ] || [ \"$cmux_ssh_attach_retry\" -lt \"$cmux_ssh_attach_reconnect_limit\" ]; then cmux_ssh_attach_can_retry=1; else cmux_ssh_attach_can_retry=0; fi",
            "  CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=\"$cmux_ssh_attach_can_retry\" CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY=\"$cmux_ssh_attach_no_progress_retry\" CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT=\"$cmux_ssh_attach_no_progress_limit\" \(command)",
            "  cmux_ssh_attach_status=$?",
            "  if [ \"$cmux_ssh_attach_status\" -ne 0 ] && [ -t 2 ]; then printf \(terminalModeReset) >&2 || true; fi",
            "  case \"$cmux_ssh_attach_status\" in",
            "    \(noProgressStatus)) cmux_ssh_attach_no_progress_retry=$((cmux_ssh_attach_no_progress_retry + 1)); cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\"; \(noProgressPolicy.limitReachedCommand) ;;",
            "    \(retryWithoutReauthenticationStatus)) cmux_ssh_attach_no_progress_retry=0 ;;",
            "    \(sessionRunningStatus)) cmux_ssh_attach_no_progress_retry=0; cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\" ;;",
            "    \(transientStatus)) cmux_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    *) exit \"$cmux_ssh_attach_status\" ;;",
            "  esac",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reconnect_unbounded\" -eq 0 ] && [ \"$cmux_ssh_attach_retry\" -ge \"$cmux_ssh_attach_reconnect_limit\" ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_retry=$((cmux_ssh_attach_retry + 1))",
            "  \(backoffBuilder.terminalInputModeResetLine)",
        ])
        let reattachingNote = "if [ -t 2 ]; then printf '\\n\\033[33m%s\\033[0m\\n' " +
            "\"$(printf \(reattachingFormat) \"$cmux_ssh_attach_retry\" " +
            "\"$cmux_ssh_attach_reconnect_limit\")\" >&2 || true; fi"
        if reauthenticates {
            // Before the first successful authentication this wrapper is bounded by the
            // authentication budget, not by `cmux_ssh_attach_reconnect_limit` (often
            // '∞'), so the note must report whichever budget actually governs it.
            let authenticationRetryFormat = String(
                localized: "cli.ssh.authRetry.status",
                defaultValue: "[cmux] ssh authentication failed with status %s; retrying (attempt %s/%s)."
            ).remoteCommandShellQuoted
            let authenticationRetryNote = "if [ -t 2 ]; then printf '\\n\\033[33m%s\\033[0m\\n' " +
                "\"$(printf \(authenticationRetryFormat) \"$cmux_ssh_attach_status\" " +
                "\"$cmux_ssh_attach_auth_retry\" \"$cmux_ssh_attach_auth_retry_limit\")\" >&2 || true; fi"
            lines.append(contentsOf: [
                "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 1 ] && [ \"$cmux_ssh_attach_auth_succeeded\" -eq 0 ]; then",
                "    \(authenticationRetryNote)",
                "  else",
                "    \(reattachingNote)",
                "  fi",
            ])
        } else {
            lines.append("  \(reattachingNote)")
        }
        lines.append(contentsOf: backoffBuilder.waitLines)
        lines.append(contentsOf: [
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -lt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=$((cmux_ssh_attach_reconnect_delay * 2)); if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi; fi",
            "done",
        ])
        return lines
    }
}

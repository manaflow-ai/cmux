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
    ///   - initialAuthentication: Whether the wrapper owns the initial foreground authentication
    ///     phase before its first attach. Compatibility callers that authenticate outside the
    ///     generated loop can disable this while retaining reauthentication after a later loss.
    /// - Returns: macOS `/bin/sh` lines implementing the shared retry state machine.
    public func lines(
        command: String,
        reauthenticates: Bool,
        initialAuthentication: Bool = true
    ) -> [String] {
        let reauthenticate = reauthenticates ? "cmux_ssh_attach_reauth_required=1" : ":"
        let authPolicy = SSHForegroundAuthenticationRetryPolicy()
        let authenticationResult = authPolicy.persistentAuthenticationResultShellLine(
            variablePrefix: "cmux_ssh_attach",
            terminalFailureCommand: "exit \"$cmux_ssh_attach_status\""
        )
        let backoffBuilder = SSHRetryBackoffScriptBuilder(context: .attach)
        let initialReauthentication = reauthenticates && initialAuthentication ? 1 : 0
        let noProgressPolicy = SSHPTYAttachExitCode.noProgressShellPolicy()
        let retryStatusFormat = String(
            localized: "cli.sshPtyAttach.retryStatus",
            defaultValue: "[cmux] SSH disconnected (%s); retry %s in %ss; input discarded."
        ).remoteCommandShellQuoted
        let hostUnreachableReason = String(
            localized: "cli.sshPtyAttach.retryReason.hostUnreachable",
            defaultValue: "host unreachable"
        ).remoteCommandShellQuoted
        let controlMasterReason = String(
            localized: "cli.sshPtyAttach.retryReason.controlMasterUnavailable",
            defaultValue: "SSH authentication/control unavailable"
        ).remoteCommandShellQuoted
        let daemonNotReadyReason = String(
            localized: "cli.sshPtyAttach.retryReason.daemonNotReady",
            defaultValue: "remote service is starting"
        ).remoteCommandShellQuoted
        let bridgeClosedReason = String(
            localized: "cli.sshPtyAttach.retryReason.bridgeClosed",
            defaultValue: "connection interrupted"
        ).remoteCommandShellQuoted
        let noProgressReason = String(
            localized: "cli.sshPtyAttach.retryReason.noProgress",
            defaultValue: "remote service made no progress"
        ).remoteCommandShellQuoted
        let reconnectedFormat = String(
            localized: "cli.sshPtyAttach.reconnected",
            defaultValue: "[cmux] remote PTY reconnected (attempt %s/%s)."
        ).remoteCommandShellQuoted
        let retryWithoutReauthenticationStatus =
            SSHPTYAttachExitCode.retryableWithoutReauthentication.rawValue
        let hostUnreachableStatus = SSHPTYAttachExitCode.hostUnreachable.rawValue
        let controlMasterUnavailableStatus = SSHPTYAttachExitCode.controlMasterUnavailable.rawValue
        let daemonNotReadyStatus = SSHPTYAttachExitCode.daemonNotReady.rawValue
        let authenticationRequiredStatus = SSHPTYAttachExitCode.authenticationRequired.rawValue
        let noProgressStatus = SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue
        let sessionRunningStatus = SSHPTYAttachExitCode.bridgeClosedSessionRunning.rawValue
        let transientStatus = SSHPTYAttachExitCode.retryableTransient.rawValue
        let terminalModeReset = SSHTerminalModeResetSequence().shellPrintfFormat.remoteCommandShellQuoted
        var lines = [
            "cmux_ssh_attach_restore_terminal() { cmux_ssh_attach_flush_status=0; if [ \"${cmux_ssh_attach_input_paused:-0}\" = 1 ] && [ -n \"${cmux_ssh_attach_cli:-}\" ]; then \"$cmux_ssh_attach_cli\" __ssh-pty-flush-input <&0 >/dev/null 2>&1; cmux_ssh_attach_flush_status=$?; fi; cmux_ssh_attach_restore_status=0; if [ -n \"${cmux_ssh_attach_terminal_state:-}\" ]; then /bin/stty \"$cmux_ssh_attach_terminal_state\" <&0 2>/dev/null; cmux_ssh_attach_restore_status=$?; fi; cmux_ssh_attach_input_paused=0; if [ \"$cmux_ssh_attach_flush_status\" -ne 0 ] || [ \"$cmux_ssh_attach_restore_status\" -ne 0 ]; then cmux_ssh_attach_terminal_control_failed=1; fi; }",
            // Persisted launchers may predate the retry policy.  A missing or
            // malformed limit must fail closed to the same finite supervisor
            // used by newly generated SSH startup scripts.
            "cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-20}\"",
            "case \"$cmux_ssh_attach_reconnect_limit\" in ''|*[!0-9]*) cmux_ssh_attach_reconnect_limit=20 ;; *) while [ \"${cmux_ssh_attach_reconnect_limit#0}\" != \"$cmux_ssh_attach_reconnect_limit\" ] && [ \"$cmux_ssh_attach_reconnect_limit\" != 0 ]; do cmux_ssh_attach_reconnect_limit=\"${cmux_ssh_attach_reconnect_limit#0}\"; done; case \"$cmux_ssh_attach_reconnect_limit\" in [1-9]|1[0-9]|20) ;; *) cmux_ssh_attach_reconnect_limit=20 ;; esac ;; esac",
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_delay=2 ;; esac",
            "cmux_ssh_attach_reconnect_max_delay=\"${CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS:-30}\"",
            "case \"$cmux_ssh_attach_reconnect_max_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_max_delay=30 ;; esac",
            "if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi",
            "cmux_ssh_attach_reconnect_initial_delay=\"$cmux_ssh_attach_reconnect_delay\"",
            "cmux_ssh_attach_retry_reason=\(bridgeClosedReason)",
            "cmux_ssh_attach_suppress_replay=0",
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
            "CMUX_SSH_PTY_ATTACH_MANAGED_RECONNECT=1",
            "export CMUX_SSH_PTY_ATTACH_MANAGED_RECONNECT",
        ])
        lines.append(contentsOf: backoffBuilder.stateInitializationLines)
        // Host/daemon phases defer foreground auth after a known successful
        // authentication; explicit auth/control failures still take the auth
        // path, preventing credentialed sessions from silently wedging.
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
            "    case \"$cmux_ssh_attach_status\" in 254) cmux_ssh_attach_retry_reason=\(hostUnreachableReason) ;; 252) cmux_ssh_attach_retry_reason=\(controlMasterReason) ;; esac",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 0 ]; then",
            "  if [ \"$cmux_ssh_attach_retry\" -lt \"$cmux_ssh_attach_reconnect_limit\" ]; then cmux_ssh_attach_can_retry=1; else cmux_ssh_attach_can_retry=0; fi",
            "  if [ -t 2 ]; then printf '\\r\\033[2K' >&2 || true; fi",
            "  CMUX_SSH_PTY_ATTACH_MANAGED_RECONNECT=1",
            "  CMUX_SSH_PTY_ATTACH_SUPPRESS_REPLAY=\"$cmux_ssh_attach_suppress_replay\"",
            "  CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=\"$cmux_ssh_attach_can_retry\"",
            "  CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY=\"$cmux_ssh_attach_no_progress_retry\"",
            "  CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT=\"$cmux_ssh_attach_no_progress_limit\"",
            "  export CMUX_SSH_PTY_ATTACH_MANAGED_RECONNECT CMUX_SSH_PTY_ATTACH_SUPPRESS_REPLAY CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT",
            "  \(command)",
            "  cmux_ssh_attach_status=$?",
            "  if [ \"$cmux_ssh_attach_status\" -ne 0 ] && [ -t 2 ]; then printf \(terminalModeReset) >&2 || true; fi",
            "  if [ \"$cmux_ssh_attach_status\" -eq 0 ] && [ \"$cmux_ssh_attach_retry\" -gt 0 ] && [ -t 2 ]; then printf '\\n\\033[32m%s\\033[0m\\n' \"$(printf \(reconnectedFormat) \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_limit\")\" >&2 || true; fi",
            "  case \"$cmux_ssh_attach_status\" in",
            "    \(hostUnreachableStatus)) cmux_ssh_attach_retry_reason=\(hostUnreachableReason); cmux_ssh_attach_no_progress_retry=0; if [ \"$cmux_ssh_attach_auth_succeeded\" -eq 0 ]; then \(reauthenticate); fi ;;",
            "    \(controlMasterUnavailableStatus)) cmux_ssh_attach_retry_reason=\(controlMasterReason); cmux_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    \(daemonNotReadyStatus)) cmux_ssh_attach_retry_reason=\(daemonNotReadyReason); cmux_ssh_attach_no_progress_retry=0; if [ \"$cmux_ssh_attach_auth_succeeded\" -eq 0 ]; then \(reauthenticate); fi ;;",
            "    \(authenticationRequiredStatus)) cmux_ssh_attach_retry_reason=\(controlMasterReason); cmux_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    \(noProgressStatus)) cmux_ssh_attach_retry_reason=\(noProgressReason); cmux_ssh_attach_no_progress_retry=$((cmux_ssh_attach_no_progress_retry + 1)); cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\"; \(noProgressPolicy.limitReachedCommand) ;;",
            "    \(retryWithoutReauthenticationStatus)) cmux_ssh_attach_retry_reason=\(daemonNotReadyReason); cmux_ssh_attach_no_progress_retry=0 ;;",
            "    \(sessionRunningStatus)) cmux_ssh_attach_retry_reason=\(bridgeClosedReason); cmux_ssh_attach_no_progress_retry=0; cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\" ;;",
            "    \(transientStatus)) cmux_ssh_attach_retry_reason=\(bridgeClosedReason); cmux_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    *) exit \"$cmux_ssh_attach_status\" ;;",
            "  esac",
            "  fi",
            "  if [ \"$cmux_ssh_attach_retry\" -ge \"$cmux_ssh_attach_reconnect_limit\" ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_retry=$((cmux_ssh_attach_retry + 1))",
            "  if [ \"$cmux_ssh_attach_retry\" -gt 0 ]; then cmux_ssh_attach_suppress_replay=1; fi",
            "  \(backoffBuilder.terminalInputModeResetLine)",
            "  if [ -t 2 ]; then printf '\\033[33m%s\\033[0m' \"$(printf \(retryStatusFormat) \"$cmux_ssh_attach_retry_reason\" \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_delay\")\" >&2 || true; fi",
        ])
        lines.append(contentsOf: backoffBuilder.waitLines)
        lines.append(contentsOf: [
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -lt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=$((cmux_ssh_attach_reconnect_delay * 2)); if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi; fi",
            "done",
        ])
        return lines
    }
}

internal import Foundation

/// Builds the shared shell retry state machine for persistent SSH PTY attachment.
///
/// Both app-restored terminals and CLI-created attach commands use this builder
/// so retry limits, backoff, authentication phases, and exit-status handling
/// cannot drift between entrypoints.
public struct SSHPTYAttachRetryScriptBuilder: Sendable {
    /// Size at which the reconnect diagnostics log restarts, so an outage that
    /// lasts a night cannot grow it without bound.
    private static let maximumDiagnosticLogBytes = 1_048_576

    private let backoff: SSHPTYAttachReconnectBackoffPolicy

    /// Creates a persistent SSH PTY retry script builder.
    ///
    /// - Parameter backoff: The delay schedule the generated loop waits between attempts.
    public init(backoff: SSHPTYAttachReconnectBackoffPolicy = SSHPTYAttachReconnectBackoffPolicy()) {
        self.backoff = backoff
    }

    /// Builds shell lines that retry PTY attachment and optional foreground authentication.
    ///
    /// The surrounding script supplies `cmux_ssh_attach_foreground_auth` when
    /// `reauthenticates` is true and installs `cmux_ssh_attach_signal_exit`
    /// before these lines execute.
    ///
    /// Consecutive attempts that fail quickly back off exponentially to the
    /// policy ceiling, and only an attempt that stayed connected long enough to
    /// be useful restarts the schedule. While a streak lasts, the loop keeps one
    /// status line naming the host state instead of appending the raw
    /// diagnostics of every attempt to the terminal; those go to a log file and
    /// are reported in full when retrying stops.
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
            terminalFailureCommand: "cmux_ssh_attach_stop_retrying; exit \"$cmux_ssh_attach_status\""
        )
        let backoffBuilder = SSHRetryBackoffScriptBuilder(context: .attach)
        let initialReauthentication = reauthenticates ? 1 : 0
        let noProgressPolicy = SSHPTYAttachExitCode.noProgressShellPolicy()
        let statusFormat = String(
            localized: "cli.sshPtyAttach.reconnectStatus",
            defaultValue: "[cmux] %s; reconnecting (attempt %s, next retry in %s seconds)."
        ).remoteCommandShellQuoted
        let diagnosticsFormat = String(
            localized: "cli.sshPtyAttach.reconnectDiagnosticsLogged",
            defaultValue: "[cmux] further reconnect errors are written to %s."
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
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-\(backoff.initialDelaySeconds)}\"",
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_delay=\(backoff.initialDelaySeconds) ;; esac",
            "cmux_ssh_attach_reconnect_max_delay=\"${CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS:-\(backoff.maximumDelaySeconds)}\"",
            "case \"$cmux_ssh_attach_reconnect_max_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_max_delay=\(backoff.maximumDelaySeconds) ;; esac",
            "if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi",
            "cmux_ssh_attach_reconnect_initial_delay=\"$cmux_ssh_attach_reconnect_delay\"",
            "cmux_ssh_attach_healthy_attempt_seconds=\(SSHPTYAttachReconnectBackoffPolicy.healthyAttemptSeconds)",
            "cmux_ssh_attach_diagnostic_log=\"${CMUX_SSH_ATTACH_DIAGNOSTIC_LOG:-${TMPDIR:-/tmp}/cmux-ssh-attach-$$.log}\"",
            "cmux_ssh_attach_attempt_log=\"$cmux_ssh_attach_diagnostic_log.attempt\"",
            "cmux_ssh_attach_consecutive_failures=0",
            "cmux_ssh_attach_status_state=",
            "cmux_ssh_attach_status_line_open=0",
            "cmux_ssh_attach_quiet=0",
            "cmux_ssh_attach_diagnostics_announced=0",
        ]
        lines.append(contentsOf: reconnectStateTextFunctionLines())
        lines.append(contentsOf: [
            // Ends the rewritable status line so the next terminal output starts
            // on its own row.
            "cmux_ssh_attach_close_status_line() { if [ \"$cmux_ssh_attach_status_line_open\" -eq 1 ]; then printf '\\n' >&2 || true; cmux_ssh_attach_status_line_open=0; fi; }",
            // Once retrying stops, the terminal is the right place for the raw
            // diagnostics of the attempt that ended it.
            "cmux_ssh_attach_stop_retrying() { cmux_ssh_attach_close_status_line; if [ \"$cmux_ssh_attach_quiet\" -eq 1 ] && [ -s \"$cmux_ssh_attach_attempt_log\" ]; then cat \"$cmux_ssh_attach_attempt_log\" >&2 || true; fi; }",
        ])
        lines.append(contentsOf: [
            "cmux_ssh_attach_run_attempt() {",
            "  CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=\"$cmux_ssh_attach_can_retry\"",
            "  CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY=\"$cmux_ssh_attach_no_progress_retry\"",
            "  CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT=\"$cmux_ssh_attach_no_progress_limit\"",
            "  export CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT",
            "  \(command)",
            "}",
        ])
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
            "  if [ \"$cmux_ssh_attach_quiet\" -eq 1 ]; then : >\"$cmux_ssh_attach_attempt_log\" 2>/dev/null || true; fi",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 1 ]; then",
            "    cmux_ssh_attach_auth_launching=1",
            "    if [ \"$cmux_ssh_attach_quiet\" -eq 1 ]; then ( cmux_ssh_attach_foreground_auth ) <&0 2>>\"$cmux_ssh_attach_attempt_log\" & else ( cmux_ssh_attach_foreground_auth ) <&0 & fi",
            "    cmux_ssh_attach_auth_pid=$!",
            "    cmux_ssh_attach_auth_launching=0",
            "    if [ -n \"${cmux_ssh_attach_pending_signal:-}\" ]; then cmux_ssh_attach_signal_exit \"$cmux_ssh_attach_pending_signal\" \"${cmux_ssh_attach_pending_signal_name:-TERM}\"; fi",
            "    wait \"$cmux_ssh_attach_auth_pid\"; cmux_ssh_attach_status=$?; cmux_ssh_attach_auth_pid=",
            "    \(authenticationResult)",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 0 ]; then",
            "  if [ \"$cmux_ssh_attach_reconnect_unbounded\" -eq 1 ] || [ \"$cmux_ssh_attach_retry\" -lt \"$cmux_ssh_attach_reconnect_limit\" ]; then cmux_ssh_attach_can_retry=1; else cmux_ssh_attach_can_retry=0; fi",
            "  cmux_ssh_attach_attempt_started=$(date +%s 2>/dev/null) || cmux_ssh_attach_attempt_started=",
            "  if [ \"$cmux_ssh_attach_quiet\" -eq 1 ]; then cmux_ssh_attach_run_attempt 2>>\"$cmux_ssh_attach_attempt_log\"; else cmux_ssh_attach_run_attempt; fi",
            "  cmux_ssh_attach_status=$?",
            "  if [ \"$cmux_ssh_attach_quiet\" -eq 1 ]; then cmux_ssh_attach_log_size=$(wc -c <\"$cmux_ssh_attach_diagnostic_log\" 2>/dev/null | tr -d ' '); if [ \"${cmux_ssh_attach_log_size:-0}\" -gt \(Self.maximumDiagnosticLogBytes) ]; then : >\"$cmux_ssh_attach_diagnostic_log\" 2>/dev/null || true; fi; cat \"$cmux_ssh_attach_attempt_log\" >>\"$cmux_ssh_attach_diagnostic_log\" 2>/dev/null || true; fi",
            "  cmux_ssh_attach_attempt_seconds=0",
            "  if [ -n \"$cmux_ssh_attach_attempt_started\" ]; then cmux_ssh_attach_attempt_ended=$(date +%s 2>/dev/null) || cmux_ssh_attach_attempt_ended=\"$cmux_ssh_attach_attempt_started\"; cmux_ssh_attach_attempt_seconds=$((cmux_ssh_attach_attempt_ended - cmux_ssh_attach_attempt_started)); fi",
            // An attempt that stayed connected is progress, whatever status it
            // ended with, so the next failure starts a fresh streak.
            "  if [ \"$cmux_ssh_attach_attempt_seconds\" -ge \"$cmux_ssh_attach_healthy_attempt_seconds\" ]; then cmux_ssh_attach_consecutive_failures=0; cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\"; cmux_ssh_attach_quiet=0; cmux_ssh_attach_status_state=; cmux_ssh_attach_close_status_line; fi",
            "  if [ \"$cmux_ssh_attach_status\" -ne 0 ] && [ -t 2 ]; then printf \(terminalModeReset) >&2 || true; fi",
            "  case \"$cmux_ssh_attach_status\" in",
            "    \(noProgressStatus)) cmux_ssh_attach_no_progress_retry=$((cmux_ssh_attach_no_progress_retry + 1)); if [ \"$cmux_ssh_attach_no_progress_retry\" -ge \"$cmux_ssh_attach_no_progress_limit\" ]; then cmux_ssh_attach_stop_retrying; fi; \(noProgressPolicy.limitReachedCommand) ;;",
            "    \(retryWithoutReauthenticationStatus)) cmux_ssh_attach_no_progress_retry=0 ;;",
            "    \(sessionRunningStatus)) cmux_ssh_attach_no_progress_retry=0 ;;",
            "    \(transientStatus)) cmux_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    *) cmux_ssh_attach_stop_retrying; exit \"$cmux_ssh_attach_status\" ;;",
            "  esac",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reconnect_unbounded\" -eq 0 ] && [ \"$cmux_ssh_attach_retry\" -ge \"$cmux_ssh_attach_reconnect_limit\" ]; then cmux_ssh_attach_stop_retrying; exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_retry=$((cmux_ssh_attach_retry + 1))",
            "  cmux_ssh_attach_consecutive_failures=$((cmux_ssh_attach_consecutive_failures + 1))",
            "  \(backoffBuilder.terminalInputModeResetLine)",
            "  if [ -t 2 ]; then",
            "    if [ \"$cmux_ssh_attach_status\" != \"$cmux_ssh_attach_status_state\" ]; then cmux_ssh_attach_close_status_line; cmux_ssh_attach_status_state=\"$cmux_ssh_attach_status\"; fi",
            // Quieting only engages once the log is proven writable; a redirect
            // that cannot open its file would fail the attempt itself.
            "    if [ \"$cmux_ssh_attach_quiet\" -eq 0 ] && : >>\"$cmux_ssh_attach_diagnostic_log\" 2>/dev/null && : >\"$cmux_ssh_attach_attempt_log\" 2>/dev/null; then",
            "      cmux_ssh_attach_quiet=1",
            "      if [ \"$cmux_ssh_attach_diagnostics_announced\" -eq 0 ]; then cmux_ssh_attach_diagnostics_announced=1; cmux_ssh_attach_close_status_line; printf '\\033[33m%s\\033[0m\\n' \"$(printf \(diagnosticsFormat) \"$cmux_ssh_attach_diagnostic_log\")\" >&2 || true; fi",
            "    fi",
            "    cmux_ssh_attach_status_text=$(printf \(statusFormat) \"$(cmux_ssh_attach_state_text \"$cmux_ssh_attach_status\")\" \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_delay\")",
            "    printf '\\r\\033[K\\033[33m%s\\033[0m' \"$cmux_ssh_attach_status_text\" >&2 || true",
            "    cmux_ssh_attach_status_line_open=1",
            "  fi",
        ])
        lines.append(contentsOf: backoffBuilder.waitLines)
        lines.append(contentsOf: [
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -lt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=$((cmux_ssh_attach_reconnect_delay * 2)); if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi; fi",
            "done",
        ])
        return lines
    }

    /// Shell function that names the host state behind one attach exit status.
    private func reconnectStateTextFunctionLines() -> [String] {
        let statuses: [SSHPTYAttachExitCode] = [
            .retryableTransient,
            .retryableWithoutReauthentication,
            .bridgeClosedWithoutProgress,
            .bridgeClosedSessionRunning,
        ]
        var lines = ["cmux_ssh_attach_state_text() {", "  case \"$1\" in"]
        for status in statuses {
            guard let state = SSHPTYAttachReconnectState(exitCode: status) else { continue }
            lines.append(
                "    \(status.rawValue)) printf '%s' \(state.localizedDescription.remoteCommandShellQuoted) ;;"
            )
        }
        lines.append(
            "    *) printf '%s' \(SSHPTYAttachReconnectState.connectionDropped.localizedDescription.remoteCommandShellQuoted) ;;"
        )
        lines.append(contentsOf: ["  esac", "}"])
        return lines
    }
}

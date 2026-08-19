internal import Foundation

/// Builds the shared shell retry state machine for persistent SSH PTY attachment.
///
/// Both app-restored terminals and CLI-created attach commands use this builder
/// so retry limits, backoff, authentication phases, and exit-status handling
/// cannot drift between entrypoints.
public struct SSHPTYAttachRetryScriptBuilder: Sendable {
    /// The largest reconnect limit the generated loop compares against.
    ///
    /// `CMUX_SSH_RECONNECT_LIMIT` is free-form text, and a value too large for
    /// shell arithmetic makes both `-lt` and `-ge` fail with `integer expression
    /// expected` instead of answering, so the limit is capped at a count no
    /// outage reaches before the host comes back.
    private static let maximumConfigurableRetryLimit = 1_000_000

    private let backoff: SSHPTYAttachReconnectBackoffPolicy

    /// Creates a persistent SSH PTY retry script builder.
    ///
    /// - Parameter backoff: The delay schedule and status wording the generated
    ///   loop uses between attempts.
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
    /// be useful restarts the schedule. While a streak lasts the loop keeps one
    /// status line, rewritten in place with the attempt count, instead of
    /// appending a fresh line and the raw diagnostics of every attempt to the
    /// terminal: the first failure of a streak shows its error output, the
    /// repeats after it are counted rather than reprinted.
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
        let statusFormat = SSHPTYAttachReconnectBackoffPolicy.statusLineFormat.remoteCommandShellQuoted
        let quietedStopMessage = SSHPTYAttachReconnectBackoffPolicy.quietedStopMessage.remoteCommandShellQuoted
        let retryWithoutReauthenticationStatus =
            SSHPTYAttachExitCode.retryableWithoutReauthentication.rawValue
        let noProgressStatus = SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue
        let sessionRunningStatus = SSHPTYAttachExitCode.bridgeClosedSessionRunning.rawValue
        let transientStatus = SSHPTYAttachExitCode.retryableTransient.rawValue
        let terminalModeReset = SSHTerminalModeResetSequence().shellPrintfFormat.remoteCommandShellQuoted
        let hardMaximumDelay = SSHPTYAttachReconnectBackoffPolicy.maximumConfigurableDelaySeconds
        var lines = [
            "cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-}\"",
            "case \"$cmux_ssh_attach_reconnect_limit\" in '') cmux_ssh_attach_reconnect_limit='∞'; cmux_ssh_attach_reconnect_unbounded=1 ;; *[!0-9]*) cmux_ssh_attach_reconnect_limit=20; cmux_ssh_attach_reconnect_unbounded=0 ;; *) cmux_ssh_attach_reconnect_unbounded=0 ;; esac",
            // Drop padding zeros first: the digit count is what caps an oversized
            // limit below, and "0000001" is one attempt, not a seven-digit one.
            "while :; do case \"$cmux_ssh_attach_reconnect_limit\" in 0?*) cmux_ssh_attach_reconnect_limit=\"${cmux_ssh_attach_reconnect_limit#0}\" ;; *) break ;; esac; done",
            "case \"$cmux_ssh_attach_reconnect_limit\" in ???????*) cmux_ssh_attach_reconnect_limit=\(Self.maximumConfigurableRetryLimit) ;; esac",
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-\(backoff.initialDelaySeconds)}\"",
            // A configured delay is free-form text. Reject non-numbers, then clamp
            // before any arithmetic: a six-digit or longer value already exceeds
            // the hard ceiling, and comparing it first would hand `sh` a number
            // it may not be able to represent.
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_delay=\(backoff.initialDelaySeconds) ;; ??????*) cmux_ssh_attach_reconnect_delay=\(hardMaximumDelay) ;; esac",
            "if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \(hardMaximumDelay) ]; then cmux_ssh_attach_reconnect_delay=\(hardMaximumDelay); fi",
            "cmux_ssh_attach_reconnect_max_delay=\"${CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS:-\(backoff.maximumDelaySeconds)}\"",
            "case \"$cmux_ssh_attach_reconnect_max_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_max_delay=\(backoff.maximumDelaySeconds) ;; ??????*) cmux_ssh_attach_reconnect_max_delay=\(hardMaximumDelay) ;; esac",
            "if [ \"$cmux_ssh_attach_reconnect_max_delay\" -gt \(hardMaximumDelay) ]; then cmux_ssh_attach_reconnect_max_delay=\(hardMaximumDelay); fi",
            "if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi",
            "cmux_ssh_attach_reconnect_initial_delay=\"$cmux_ssh_attach_reconnect_delay\"",
            "cmux_ssh_attach_healthy_attempt_seconds=\(SSHPTYAttachReconnectBackoffPolicy.healthyAttemptSeconds)",
            "cmux_ssh_attach_status_line_open=0",
            "cmux_ssh_attach_quiet=0",
            // Ends the rewritable status line so the next terminal output starts
            // on its own row.
            "cmux_ssh_attach_close_status_line() { if [ \"$cmux_ssh_attach_status_line_open\" -eq 1 ]; then printf '\\n' >&2 || true; cmux_ssh_attach_status_line_open=0; fi; }",
            // Retrying has ended, so say that repeats were hidden rather than let
            // the last silenced attempt look like it failed without a reason. A
            // session that ended cleanly needs no such note.
            "cmux_ssh_attach_stop_retrying() { cmux_ssh_attach_close_status_line; if [ \"$cmux_ssh_attach_quiet\" -eq 1 ]; then cmux_ssh_attach_quiet=0; if [ \"${cmux_ssh_attach_status:-0}\" -ne 0 ]; then printf '\\033[33m%s\\033[0m\\n' \(quietedStopMessage) >&2 || true; fi; fi; }",
            // A compound attach command cannot take an assignment prefix, and the
            // quiet path needs a redirect, so one attempt gets its own function.
            "cmux_ssh_attach_run_attempt() {",
            "  CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=\"$cmux_ssh_attach_can_retry\"",
            "  CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY=\"$cmux_ssh_attach_no_progress_retry\"",
            "  CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT=\"$cmux_ssh_attach_no_progress_limit\"",
            "  export CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT",
            "  \(command)",
            "}",
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
            // Foreground authentication talks to the user, so it runs outside the
            // quieted attempt and ends the status line before prompting. The
            // streak itself continues: an outage that reauthenticates every cycle
            // must not print the same attach error once per cycle.
            "    cmux_ssh_attach_close_status_line",
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
            "  cmux_ssh_attach_attempt_started=$(date +%s 2>/dev/null) || cmux_ssh_attach_attempt_started=",
            "  if [ \"$cmux_ssh_attach_quiet\" -eq 1 ]; then cmux_ssh_attach_run_attempt 2>/dev/null; else cmux_ssh_attach_run_attempt; fi",
            "  cmux_ssh_attach_status=$?",
            "  cmux_ssh_attach_attempt_seconds=0",
            "  if [ -n \"$cmux_ssh_attach_attempt_started\" ]; then cmux_ssh_attach_attempt_ended=$(date +%s 2>/dev/null) || cmux_ssh_attach_attempt_ended=\"$cmux_ssh_attach_attempt_started\"; cmux_ssh_attach_attempt_seconds=$((cmux_ssh_attach_attempt_ended - cmux_ssh_attach_attempt_started)); fi",
            // An attempt that stayed connected is progress, whatever status it
            // ended with, so the next failure starts a fresh streak and speaks up.
            "  if [ \"$cmux_ssh_attach_attempt_seconds\" -ge \"$cmux_ssh_attach_healthy_attempt_seconds\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\"; cmux_ssh_attach_quiet=0; cmux_ssh_attach_close_status_line; fi",
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
            "  \(backoffBuilder.terminalInputModeResetLine)",
            "  if [ -t 2 ]; then",
            "    cmux_ssh_attach_status_text=$(printf \(statusFormat) \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_delay\")",
            "    printf '\\r\\033[K\\033[33m%s\\033[0m' \"$cmux_ssh_attach_status_text\" >&2 || true",
            "    cmux_ssh_attach_status_line_open=1",
            // The cause of this streak has now been printed once, so the attempts
            // that repeat it are counted in the line above instead.
            "    cmux_ssh_attach_quiet=1",
            "  fi",
        ])
        lines.append(contentsOf: backoffBuilder.waitLines)
        lines.append(contentsOf: [
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -lt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=$((cmux_ssh_attach_reconnect_delay * 2)); if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi; fi",
            "done",
        ])
        return lines
    }
}

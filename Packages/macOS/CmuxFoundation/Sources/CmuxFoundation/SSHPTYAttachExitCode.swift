import Foundation

/// Describes the process exit status and retry policy for an SSH PTY attach.
///
/// Status 252 has a bounded consecutive-failure budget, while statuses 251,
/// 254, and 255 use the general reconnect budget.
public enum SSHPTYAttachExitCode: Int32 {
    private static let healthyBridgeUptime: Double = 30

    /// A non-retryable attach failure.
    case fatal = 1

    /// Temporary daemon-side admission pressure that should retry without reauthentication.
    case retryableWithoutReauthentication = 251

    /// A rapidly closed bridge that produced no live remote PTY output.
    case bridgeClosedWithoutProgress = 252

    /// A persistent PTY session that no longer exists and must be respawned.
    case sessionNotFound = 253

    /// A closed established bridge that must preserve its persistent PTY session for reattach.
    ///
    /// This covers both a session confirmed running and a post-close liveness
    /// query made inconclusive by the tunnel replacement race. In either case,
    /// retiring the session would destroy recoverable state; the next
    /// `--require-existing` attach is the authoritative probe.
    case bridgeClosedSessionRunning = 254

    /// A transient transport or daemon failure that may succeed after reconnecting.
    case retryableTransient = 255

    /// Whether the general persistent-attach wrapper retries this status.
    ///
    /// Failures with these statuses keep app-side surface tracking intact
    /// because the wrapper immediately reattaches on the same surface.
    public var isWrapperRetryable: Bool {
        self == .retryableWithoutReauthentication ||
            self == .bridgeClosedSessionRunning ||
            self == .retryableTransient
    }

    /// Determines whether a bridge closed before demonstrating useful progress.
    ///
    /// - Parameters:
    ///   - receivedLiveOutput: Whether the bridge delivered output after its
    ///     initial scrollback replay.
    ///   - bridgeUptime: The number of seconds the ready bridge remained open.
    /// - Returns: `true` for a rapid closure with no live output.
    public static func bridgeClosureMadeNoProgress(
        receivedLiveOutput: Bool,
        bridgeUptime: Double
    ) -> Bool {
        // A bridge that remains connected through an ordinary idle interval is
        // healthy even when the remote shell has not emitted output.
        !receivedLiveOutput && bridgeUptime >= 0 && bridgeUptime < healthyBridgeUptime
    }

    /// Determines whether another no-progress retry remains in the bounded budget.
    ///
    /// - Parameters:
    ///   - currentRetry: The zero-based number of prior no-progress retries.
    ///   - limit: The maximum number of consecutive no-progress attempts.
    /// - Returns: `true` when another attempt is allowed.
    public static func hasNoProgressRetryRemaining(currentRetry: Int, limit: Int) -> Bool {
        currentRetry >= 0 && limit > 0 && currentRetry + 1 < limit
    }

    /// Builds the POSIX shell loop shared by persistent SSH PTY attach entry points.
    ///
    /// - Parameters:
    ///   - command: The shell command that performs one attach attempt.
    ///   - reauthenticates: Whether transient failures should request foreground authentication.
    /// - Returns: Shell source lines implementing reconnect and no-progress budgets.
    public static func retryLoopLines(command: String, reauthenticates: Bool) -> [String] {
        let reauthenticate = reauthenticates ? "cmux_ssh_attach_reauth_required=1" : ":"
        let noProgressPolicy = noProgressShellPolicy()
        let reattachingFormat = String(
            localized: "cli.sshPtyAttach.bridgeClosedReattaching",
            defaultValue: "[cmux] remote PTY bridge closed; reattaching (attempt %s/%s)."
        ).remoteCommandShellQuoted
        let retryWithoutReauthenticationStatus = retryableWithoutReauthentication.rawValue
        let sessionRunningStatus = bridgeClosedSessionRunning.rawValue
        let transientStatus = retryableTransient.rawValue
        let terminalModeReset = SSHTerminalModeResetSequence().shellPrintfFormat.remoteCommandShellQuoted

        return [
            "cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-20}\"",
            "case \"$cmux_ssh_attach_reconnect_limit\" in ''|*[!0-9]*) cmux_ssh_attach_reconnect_limit=20 ;; *) while [ \"${cmux_ssh_attach_reconnect_limit#0}\" != \"$cmux_ssh_attach_reconnect_limit\" ] && [ \"$cmux_ssh_attach_reconnect_limit\" != 0 ]; do cmux_ssh_attach_reconnect_limit=\"${cmux_ssh_attach_reconnect_limit#0}\"; done; case \"$cmux_ssh_attach_reconnect_limit\" in [1-9]|1[0-9]|20) ;; *) cmux_ssh_attach_reconnect_limit=20 ;; esac ;; esac",
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_delay=2 ;; esac",
            "cmux_ssh_attach_reconnect_max_delay=\"${CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS:-30}\"",
            "case \"$cmux_ssh_attach_reconnect_max_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_max_delay=30 ;; esac",
            "if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi",
            "cmux_ssh_attach_reconnect_initial_delay=\"$cmux_ssh_attach_reconnect_delay\"",
        ] + noProgressPolicy.configurationLines + [
            "cmux_ssh_attach_no_progress_retry=0",
            "cmux_ssh_attach_retry=0",
            "cmux_ssh_attach_reauth_required=0",
            "while :; do",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 1 ]; then",
            "    cmux_ssh_attach_foreground_auth",
            "    cmux_ssh_attach_status=$?",
            "    if [ \"$cmux_ssh_attach_status\" -eq 0 ]; then cmux_ssh_attach_reauth_required=0; elif [ \"$cmux_ssh_attach_status\" -ne \(transientStatus) ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 0 ]; then",
            "  if [ \"$cmux_ssh_attach_retry\" -lt \"$cmux_ssh_attach_reconnect_limit\" ]; then cmux_ssh_attach_can_retry=1; else cmux_ssh_attach_can_retry=0; fi",
            "  CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=\"$cmux_ssh_attach_can_retry\" CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY=\"$cmux_ssh_attach_no_progress_retry\" CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT=\"$cmux_ssh_attach_no_progress_limit\" \(command)",
            "  cmux_ssh_attach_status=$?",
            "  if [ \"$cmux_ssh_attach_status\" -ne 0 ] && [ -t 2 ]; then printf \(terminalModeReset) >&2 || true; fi",
            "  case \"$cmux_ssh_attach_status\" in",
            "    \(noProgressPolicy.status)) cmux_ssh_attach_no_progress_retry=$((cmux_ssh_attach_no_progress_retry + 1)); cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\"; \(noProgressPolicy.limitReachedCommand) ;;",
            "    \(retryWithoutReauthenticationStatus)) cmux_ssh_attach_no_progress_retry=0 ;;",
            "    \(sessionRunningStatus)) cmux_ssh_attach_no_progress_retry=0; cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\" ;;",
            "    \(transientStatus)) cmux_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    *) exit \"$cmux_ssh_attach_status\" ;;",
            "  esac",
            "  fi",
            "  if [ \"$cmux_ssh_attach_retry\" -ge \"$cmux_ssh_attach_reconnect_limit\" ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_retry=$((cmux_ssh_attach_retry + 1))",
            "  if [ -t 2 ]; then printf '\\n\\033[33m%s\\033[0m\\n' \"$(printf \(reattachingFormat) \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_limit\")\" >&2 || true; fi",
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -gt 0 ]; then sleep \"$cmux_ssh_attach_reconnect_delay\"; fi",
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -lt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=$((cmux_ssh_attach_reconnect_delay * 2)); if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi; fi",
            "done",
        ]
    }

    /// Builds a bounded no-progress sub-loop for a wrapper that already owns
    /// general reconnect and foreground-authentication policy.
    ///
    /// Status 252 is consumed until its health budget is exhausted, with terminal
    /// reporting modes reset before each reattach. All other statuses, including
    /// 251, 254, and 255, return unchanged to the enclosing wrapper so its existing
    /// reconnect and reauthentication behavior remains the single owner of those
    /// transitions.
    ///
    /// The attach environment is exported on its own lines rather than as an
    /// assignment prefix, because a prefix is only legal before a simple command
    /// and callers legitimately pass compound commands.
    ///
    /// - Parameter command: The shell command that performs one attach attempt.
    /// - Returns: Shell source lines implementing the no-progress budget.
    public static func noProgressRetryLoopLines(command: String) -> [String] {
        let policy = noProgressShellPolicy()
        let terminalModeReset = SSHTerminalModeResetSequence().shellPrintfFormat.remoteCommandShellQuoted

        return policy.configurationLines + [
            "cmux_ssh_attach_no_progress_retry=0",
            "while :; do",
            "  CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY=\"$cmux_ssh_attach_no_progress_retry\"",
            "  CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT=\"$cmux_ssh_attach_no_progress_limit\"",
            "  export CMUX_SSH_PTY_ATTACH_NO_PROGRESS_RETRY CMUX_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT",
            "  \(command)",
            "  cmux_ssh_attach_status=$?",
            "  if [ \"$cmux_ssh_attach_status\" -eq \(policy.status) ] && [ -t 2 ]; then printf \(terminalModeReset) >&2 || true; fi",
            "  if [ \"$cmux_ssh_attach_status\" -ne \(policy.status) ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_no_progress_retry=$((cmux_ssh_attach_no_progress_retry + 1))",
            "  \(policy.limitReachedCommand)",
            "done",
        ]
    }

    static func noProgressShellPolicy() -> (
        configurationLines: [String],
        status: Int32,
        limitReachedCommand: String
    ) {
        let pluralFormat = String(
            localized: "cli.sshPtyAttach.noProgressRetryLimitReached.other",
            defaultValue: "[cmux] remote PTY bridge made no progress after %s attempts; stopping retries."
        ).remoteCommandShellQuoted
        let singularFormat = String(
            localized: "cli.sshPtyAttach.noProgressRetryLimitReached.one",
            defaultValue: "[cmux] remote PTY bridge made no progress after %s attempt; stopping retries."
        ).remoteCommandShellQuoted
        return (
            configurationLines: [
                "cmux_ssh_attach_no_progress_limit=\"${CMUX_SSH_PTY_NO_PROGRESS_RETRY_LIMIT:-3}\"",
                "case \"$cmux_ssh_attach_no_progress_limit\" in ''|*[!0-9]*|0*) cmux_ssh_attach_no_progress_limit=3 ;; esac",
            ],
            status: bridgeClosedWithoutProgress.rawValue,
            limitReachedCommand: "if [ \"$cmux_ssh_attach_no_progress_retry\" -ge \"$cmux_ssh_attach_no_progress_limit\" ]; then if [ \"$cmux_ssh_attach_no_progress_limit\" -eq 1 ]; then cmux_ssh_attach_limit_format=\(singularFormat); else cmux_ssh_attach_limit_format=\(pluralFormat); fi; printf '\\n\\033[31m%s\\033[0m\\n' \"$(printf \"$cmux_ssh_attach_limit_format\" \"$cmux_ssh_attach_no_progress_limit\")\" >&2 || true; exit 1; fi"
        )
    }

    /// Classifies a textual bridge-establishment failure into its attach exit status.
    ///
    /// - Parameter rawDescription: The daemon or transport failure description.
    /// - Returns: The exit status that drives wrapper retry or respawn behavior.
    public static func classifyBridgeEstablishmentFailure(
        _ rawDescription: String
    ) -> SSHPTYAttachExitCode {
        classifyNormalized(rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Classifies a structured bridge-establishment failure into its attach exit status.
    ///
    /// - Parameters:
    ///   - code: The structured daemon error code, when supplied.
    ///   - message: The daemon or transport failure message.
    /// - Returns: The exit status that drives wrapper retry or respawn behavior.
    public static func classifyBridgeEstablishmentFailure(
        code: String?,
        message: String
    ) -> SSHPTYAttachExitCode {
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedCode == "pty_session_not_found" {
            return .sessionNotFound
        }
        if normalizedCode == "pty_lifecycle_closed" {
            return .fatal
        }
        if normalizedCode == "unavailable" {
            return .retryableWithoutReauthentication
        }
        let rawDescription = [normalizedCode, message]
            .compactMap { $0 }
            .joined(separator: " ")
        return classifyBridgeEstablishmentFailure(rawDescription)
    }

    private static func classifyNormalized(_ description: String) -> SSHPTYAttachExitCode {
        if description.contains("pty_session_not_found") ||
            ((description.contains("persistent ssh pty session") ||
              description.contains("persistent pty session")) &&
             (description.contains("not running") ||
              description.contains("no longer running"))) {
            return .sessionNotFound
        }

        if description.contains("timed out") ||
            description.contains("timeout") ||
            description.contains("did not respond in time") ||
            description.contains("remote connection is not active") ||
            description.contains("remote daemon is not ready") ||
            description.contains("remote daemon tunnel is not ready") ||
            description.contains("pty_input_queue_full") ||
            description.contains("pty input queue is full") ||
            description.contains("input is temporarily backed up") ||
            description.contains("connection refused") ||
            description.contains("connection reset") {
            return .retryableTransient
        }

        return .fatal
    }
}

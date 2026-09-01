import Foundation

/// Describes the process exit status and retry policy for an SSH PTY attach.
///
/// Status 252 has a bounded consecutive-failure budget, statuses 247–250 carry
/// managed transport/authentication phases, and statuses 251, 254, and 255 use
/// the general reconnect budget.
public enum SSHPTYAttachExitCode: Int32 {
    private static let healthyBridgeUptime: Double = 30

    /// A non-retryable attach failure.
    case fatal = 1

    /// Temporary daemon-side admission pressure that should retry without reauthentication.
    case retryableWithoutReauthentication = 251

    /// The SSH endpoint cannot currently be reached.
    ///
    /// This status is emitted only to a managed reconnect wrapper so the
    /// wrapper can present a concise reason without exposing OpenSSH stderr.
    case hostUnreachable = 247

    /// The SSH control connection is stale or wedged and needs reauthentication.
    ///
    /// This status is emitted only to a managed reconnect wrapper so the
    /// wrapper can distinguish a control-master failure from a host outage.
    case controlMasterUnavailable = 248

    /// The remote cmux daemon is still starting or its tunnel is not ready.
    ///
    /// This status is emitted only to a managed reconnect wrapper so it can
    /// keep the user-facing state separate from host reachability.
    case daemonNotReady = 249

    /// The remote endpoint requires foreground authentication before retrying.
    case authenticationRequired = 250

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
        self == .hostUnreachable ||
            self == .controlMasterUnavailable ||
            self == .daemonNotReady ||
            self == .authenticationRequired ||
            self == .retryableWithoutReauthentication ||
            self == .bridgeClosedSessionRunning ||
            self == .retryableTransient
    }

    /// Whether a managed retry must run the foreground authentication phase.
    ///
    /// A confirmed host/daemon transport outage deliberately waits for the
    /// app-side reachability owner instead of launching another noisy SSH
    /// prompt. Explicit control-master, authentication, and unknown transient
    /// failures retain the historical authentication behavior.
    public var requiresForegroundAuthentication: Bool {
        self == .controlMasterUnavailable ||
            self == .authenticationRequired ||
            self == .retryableTransient
    }

    /// Refines a retryable error for the managed wrapper's status line.
    ///
    /// The bridge protocol intentionally keeps its transport error payload
    /// human-readable for older clients. A managed wrapper can still classify
    /// the stable diagnostic phrases into a small set of user-facing phases;
    /// direct invocations retain their original status and diagnostic output.
    ///
    /// - Parameter rawDescription: The bridge or transport diagnostic.
    /// - Returns: A typed managed-retry status, or this status when no stable
    ///   phase can be inferred.
    public func managedRetryStatus(for rawDescription: String) -> Self {
        guard isWrapperRetryable else { return self }
        let description = rawDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if description.range(
            of: #"[^[:space:]]+@[^[:space:]]+: permission denied"#,
            options: .regularExpression
        ) != nil ||
            description.contains("authentication failed") ||
            description.contains("host key verification failed") ||
            description.contains("too many authentication failures") {
            return .authenticationRequired
        }
        if description.contains("remote daemon is not ready") ||
            description.contains("remote daemon tunnel is not ready") ||
            description.contains("remote connection is not active") ||
            description == "remote pty operation failed" ||
            description.hasSuffix(": remote pty operation failed") ||
            description.contains("remote daemon did not respond in time") ||
            description.contains("did not respond in time") ||
            description.contains("timed out waiting for remote pty") {
            return .daemonNotReady
        }
        if description.contains("mux_client_request_session") ||
            description.contains("control master") ||
            description.contains("control socket") ||
            description.contains("broken pipe") {
            return .controlMasterUnavailable
        }
        if description.contains("ssh: connect to host") ||
            description.contains("connect to host") ||
            description.contains("operation timed out") ||
            description.contains("connection timed out") ||
            description.contains("network is unreachable") ||
            description.contains("network is down") ||
            description.contains("no route to host") ||
            description.contains("host is down") ||
            description.contains("connection refused") ||
            description.contains("could not resolve hostname") ||
            description.contains("temporary failure in name resolution") ||
            description.contains("name or service not known") {
            return .hostUnreachable
        }
        return self
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

    /// Builds the shared persistent-attach retry loop.
    ///
    /// This compatibility entry point delegates to
    /// ``SSHPTYAttachRetryScriptBuilder`` so older package clients keep their
    /// source compatibility without retaining a second retry implementation.
    ///
    /// - Parameters:
    ///   - command: Shell command that performs one attach attempt.
    ///   - reauthenticates: Whether foreground authentication is available.
    /// - Returns: Shell lines implementing the shared retry state machine.
    @available(
        *,
        deprecated,
        message: "Use SSHPTYAttachRetryScriptBuilder.lines(command:reauthenticates:initialAuthentication:) with initialAuthentication: false"
    )
    public static func retryLoopLines(command: String, reauthenticates: Bool) -> [String] {
        SSHPTYAttachRetryScriptBuilder().lines(
            command: command,
            reauthenticates: reauthenticates,
            initialAuthentication: false
        )
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

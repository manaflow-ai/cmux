import Foundation

/// The host state behind one failed persistent SSH PTY attach attempt.
///
/// The retry wrapper names this state in its status line instead of echoing the
/// internal diagnostic text of the attempt, because remediation differs per
/// state: an unreachable host needs the host back, a busy or not-ready daemon
/// only needs time, and a dropped connection keeps its remote session alive.
public enum SSHPTYAttachReconnectState: Sendable, CaseIterable {
    /// The transport could not reach the host at all.
    case hostUnreachable

    /// The remote daemon rejected the attachment under admission pressure.
    case remoteDaemonBusy

    /// The bridge opened but the remote daemon was not serving the PTY yet.
    case remoteDaemonNotReady

    /// An established bridge closed while the remote PTY session kept running.
    case connectionDropped

    /// Maps an attach exit status onto the state shown while reconnecting.
    ///
    /// - Parameter exitCode: The status the attach attempt exited with.
    /// - Returns: The state, or `nil` for statuses the wrapper does not retry.
    public init?(exitCode: SSHPTYAttachExitCode) {
        switch exitCode {
        case .retryableTransient:
            self = .hostUnreachable
        case .retryableWithoutReauthentication:
            self = .remoteDaemonBusy
        case .bridgeClosedWithoutProgress:
            self = .remoteDaemonNotReady
        case .bridgeClosedSessionRunning:
            self = .connectionDropped
        case .fatal, .sessionNotFound:
            return nil
        }
    }

    /// The localized host state named in the reconnect status line.
    public var localizedDescription: String {
        switch self {
        case .hostUnreachable:
            String(
                localized: "cli.sshPtyAttach.reconnectState.hostUnreachable",
                defaultValue: "SSH host is unreachable"
            )
        case .remoteDaemonBusy:
            String(
                localized: "cli.sshPtyAttach.reconnectState.remoteDaemonBusy",
                defaultValue: "remote cmux daemon is busy"
            )
        case .remoteDaemonNotReady:
            String(
                localized: "cli.sshPtyAttach.reconnectState.remoteDaemonNotReady",
                defaultValue: "remote cmux daemon is not ready"
            )
        case .connectionDropped:
            String(
                localized: "cli.sshPtyAttach.reconnectState.connectionDropped",
                defaultValue: "connection to the remote host dropped"
            )
        }
    }
}

/// The delay schedule the persistent SSH PTY attach wrapper waits between attempts.
///
/// Reattachment stays unbounded, because a host that sleeps overnight must still
/// be there in the morning, so the flood control is the schedule rather than a
/// retry limit: consecutive failures back off exponentially up to a ceiling, and
/// only an attempt that stayed connected long enough to be useful returns the
/// schedule to its initial delay. Exit statuses do not reset it; a bridge that
/// closes immediately is a failed attempt no matter which status it reports.
public struct SSHPTYAttachReconnectBackoffPolicy: Sendable, Equatable {
    /// The default first delay, in seconds, after a failed attempt.
    public static let defaultInitialDelaySeconds = 2

    /// The default ceiling, in seconds, the delay grows to.
    public static let defaultMaximumDelaySeconds = 30

    /// How long an attempt must last to count as progress rather than a failure.
    ///
    /// This matches the bridge uptime that already separates a healthy bridge
    /// from a rapid no-progress closure, so both budgets agree on "connected".
    public static let healthyAttemptSeconds = Int(SSHPTYAttachExitCode.healthyBridgeUptime)

    /// The delay waited after the first failure of a streak.
    public let initialDelaySeconds: Int

    /// The ceiling the delay never grows past.
    public let maximumDelaySeconds: Int

    /// Creates a schedule, clamping an inverted or non-positive configuration.
    public init(
        initialDelaySeconds: Int = defaultInitialDelaySeconds,
        maximumDelaySeconds: Int = defaultMaximumDelaySeconds
    ) {
        let maximum = max(1, maximumDelaySeconds)
        self.maximumDelaySeconds = maximum
        self.initialDelaySeconds = min(max(1, initialDelaySeconds), maximum)
    }

    /// The delay to wait before the retry that follows a streak of failures.
    ///
    /// - Parameter consecutiveFailures: The number of failed attempts in the
    ///   current streak, counting the one that just failed.
    /// - Returns: Seconds to wait before the next attempt.
    public func delaySeconds(afterConsecutiveFailures consecutiveFailures: Int) -> Int {
        guard consecutiveFailures > 1 else { return initialDelaySeconds }
        var delay = initialDelaySeconds
        for _ in 1..<consecutiveFailures {
            if delay >= maximumDelaySeconds { return maximumDelaySeconds }
            delay *= 2
        }
        return min(delay, maximumDelaySeconds)
    }

    /// Whether an attempt stayed connected long enough to restart the schedule.
    ///
    /// - Parameter durationSeconds: How long the attempt ran before it failed.
    /// - Returns: `true` when the next failure starts a fresh streak.
    public func attemptProvedProgress(durationSeconds: Int) -> Bool {
        durationSeconds >= Self.healthyAttemptSeconds
    }
}

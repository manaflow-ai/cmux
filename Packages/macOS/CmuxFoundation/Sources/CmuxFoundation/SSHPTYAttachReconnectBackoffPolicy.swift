import Foundation

/// The delay schedule and status wording the persistent SSH PTY attach wrapper
/// uses while it reattaches.
///
/// Reattachment stays unbounded, because a host that sleeps overnight must still
/// be there in the morning, so the flood control is the schedule rather than a
/// retry limit: consecutive failures back off exponentially up to a ceiling, and
/// only an attempt that stayed connected long enough to be useful returns the
/// schedule to its initial delay. Exit statuses do not reset it; a bridge that
/// closes immediately is a failed attempt no matter which status it reports.
///
/// The wording is deliberately neutral about the cause. The wrapper only sees an
/// attach exit status, and a single status covers several host states: 255 is
/// returned for a connect timeout, a refused connection, and a remote daemon
/// that is not ready yet. Naming one of those in the status line would be a
/// confident guess, so the line reports the fact the wrapper does know, that the
/// connection is gone and when the next attempt runs.
public struct SSHPTYAttachReconnectBackoffPolicy: Sendable, Equatable {
    /// The default first delay, in seconds, after a failed attempt.
    public static let defaultInitialDelaySeconds = 2

    /// The default ceiling, in seconds, the delay grows to.
    public static let defaultMaximumDelaySeconds = 30

    /// The largest delay any configuration can select, in seconds.
    ///
    /// The environment overrides the generated script reads are free-form text,
    /// so a caller can ask for a delay of twenty digits. Clamping to a day keeps
    /// both the shell arithmetic and this type inside a range every `sh` handles,
    /// and a reattach interval longer than a day is indistinguishable from never.
    public static let maximumConfigurableDelaySeconds = 86_400

    /// How long an attempt must last to count as progress rather than a failure.
    ///
    /// This matches the bridge uptime that already separates a healthy bridge
    /// from a rapid no-progress closure, so both budgets agree on "connected".
    public static let healthyAttemptSeconds = Int(SSHPTYAttachExitCode.healthyBridgeUptime)

    /// The delay waited after the first failure of a streak.
    public let initialDelaySeconds: Int

    /// The ceiling the delay never grows past.
    public let maximumDelaySeconds: Int

    /// Creates a schedule, clamping an inverted, non-positive, or absurd configuration.
    public init(
        initialDelaySeconds: Int = defaultInitialDelaySeconds,
        maximumDelaySeconds: Int = defaultMaximumDelaySeconds
    ) {
        let maximum = min(max(1, maximumDelaySeconds), Self.maximumConfigurableDelaySeconds)
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
            // Compare before doubling: a ceiling near `Int.max` would trap on the
            // multiplication that a post-hoc `min` was meant to absorb.
            if delay > maximumDelaySeconds / 2 { return maximumDelaySeconds }
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

    /// The localized status format, with `%s` placeholders for attempt and delay.
    ///
    /// The generated shell loop renders it with `printf`, and
    /// ``statusLine(attempt:delaySeconds:)`` renders the same format in Swift so
    /// the wording can be tested without running a script.
    public static var statusLineFormat: String {
        String(
            localized: "cli.sshPtyAttach.reconnectStatus",
            defaultValue: "[cmux] reconnecting to the remote PTY (attempt %s, next retry in %ss)."
        )
    }

    /// The localized note printed when retrying stops after hiding repeats.
    public static var quietedStopMessage: String {
        String(
            localized: "cli.sshPtyAttach.reconnectQuietedStop",
            defaultValue: "[cmux] stopped reconnecting to the remote PTY; repeated error output was hidden while retrying. Reattach to see it, or check the connection to the host."
        )
    }

    /// The status line shown before the retry that follows a streak of failures.
    ///
    /// - Parameters:
    ///   - attempt: The reattach attempt the wrapper is about to make.
    ///   - delaySeconds: Seconds the wrapper waits before that attempt.
    /// - Returns: The single line the pane keeps while the streak lasts.
    public func statusLine(attempt: Int, delaySeconds: Int) -> String {
        Self.rendered(Self.statusLineFormat, ["\(attempt)", "\(delaySeconds)"])
    }

    /// Substitutes `%s` placeholders positionally, the way `printf` would.
    ///
    /// The format is shared with a shell `printf`, so it carries `%s` rather than
    /// the `%@`/`%ld` specifiers `String(format:)` expects.
    private static func rendered(_ format: String, _ arguments: [String]) -> String {
        var result = ""
        var remainder = Substring(format)
        var next = arguments.startIndex
        while let placeholder = remainder.range(of: "%s") {
            result += remainder[remainder.startIndex..<placeholder.lowerBound]
            if next < arguments.endIndex {
                result += arguments[next]
                next += 1
            } else {
                result += "%s"
            }
            remainder = remainder[placeholder.upperBound...]
        }
        return result + remainder
    }
}

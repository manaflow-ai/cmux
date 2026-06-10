import Foundation

/// Outcome of a quick reachability probe against the SSH endpoint of a remote
/// workspace, used by the auto-reconnect loop to decide whether retrying makes
/// sense at all.
enum WorkspaceRemoteHostProbeOutcome: Equatable, Sendable {
    /// A TCP connection to the resolved SSH endpoint succeeded.
    case reachable
    /// The endpoint could not be reached (DNS failure, connection refused,
    /// timeout, or no route). The associated reason is a short human-readable
    /// detail for logs and connection-state messages.
    case unreachable(reason: String)
    /// Reachability could not be determined (for example ProxyCommand-based
    /// transports that cannot be probed with a direct TCP connection). The
    /// policy must never suspend the reconnect loop based on this outcome.
    case indeterminate
}

/// Pure decision logic for the SSH remote workspace auto-reconnect loop
/// (https://github.com/manaflow-ai/cmux/issues/5734).
///
/// While the host stays reachable the loop keeps its existing exponential
/// backoff behavior. Once consecutive reachability probes keep failing, the
/// loop should suspend instead of retrying indefinitely, leaving the user in
/// control of when reconnection happens.
enum WorkspaceRemoteReconnectPolicy {
    enum Decision: Equatable, Sendable {
        /// Keep the scheduled backoff retry armed.
        case scheduleRetry
        /// Halt the automatic reconnect loop and wait for a manual reconnect.
        case suspend
    }

    struct Evaluation: Equatable, Sendable {
        /// Consecutive failed probes after accounting for the latest outcome.
        let consecutiveUnreachableProbes: Int
        let decision: Decision
    }

    /// Number of consecutive unreachable probes after which the automatic
    /// reconnect loop suspends. Sized to absorb short network transitions
    /// (sleep/wake, wifi handoff) without retrying indefinitely against a
    /// host that cannot be reached.
    static let maxConsecutiveUnreachableProbes = 3

    static func evaluate(
        outcome: WorkspaceRemoteHostProbeOutcome,
        previousConsecutiveUnreachableProbes: Int
    ) -> Evaluation {
        switch outcome {
        case .reachable, .indeterminate:
            return Evaluation(consecutiveUnreachableProbes: 0, decision: .scheduleRetry)
        case .unreachable:
            let streak = previousConsecutiveUnreachableProbes + 1
            return Evaluation(
                consecutiveUnreachableProbes: streak,
                decision: streak >= Self.maxConsecutiveUnreachableProbes ? .suspend : .scheduleRetry
            )
        }
    }
}

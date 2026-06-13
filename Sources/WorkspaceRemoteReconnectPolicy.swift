import Foundation

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

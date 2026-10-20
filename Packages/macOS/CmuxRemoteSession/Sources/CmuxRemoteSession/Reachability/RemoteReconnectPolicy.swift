/// Pure decision logic for the SSH remote workspace auto-reconnect loop
/// (https://github.com/manaflow-ai/cmux/issues/5734).
///
/// While the host stays reachable the loop keeps its existing exponential
/// backoff behavior. Once consecutive reachability probes keep failing, the
/// loop should suspend instead of retrying indefinitely, leaving the user in
/// control of when reconnection happens.
///
/// Lifted from the app's `WorkspaceRemoteReconnectPolicy` namespace enum,
/// converted to a stateless value type per the no-namespace-enums convention.
public struct RemoteReconnectPolicy: Sendable {
    /// What the reconnect loop should do after a probe outcome.
    public enum Decision: Equatable, Sendable {
        /// Keep the scheduled backoff retry armed.
        case scheduleRetry
        /// Halt the automatic reconnect loop and wait for a manual reconnect.
        case suspend
    }

    /// The policy's verdict for one probe outcome.
    public struct Evaluation: Equatable, Sendable {
        /// Consecutive failed probes after accounting for the latest outcome.
        public let consecutiveUnreachableProbes: Int
        /// The decision for the reconnect loop.
        public let decision: Decision

        /// Creates an evaluation (public for test fixtures).
        public init(consecutiveUnreachableProbes: Int, decision: Decision) {
            self.consecutiveUnreachableProbes = consecutiveUnreachableProbes
            self.decision = decision
        }
    }

    /// Number of consecutive unreachable probes after which the automatic
    /// reconnect loop suspends. Sized to absorb short network transitions
    /// (sleep/wake, wifi handoff) without retrying indefinitely against a
    /// host that cannot be reached.
    public let maxConsecutiveUnreachableProbes = 3

    /// Creates the policy.
    public init() {}

    /// Evaluates one probe outcome against the running unreachable streak.
    public func evaluate(
        outcome: RemoteHostProbeOutcome,
        previousConsecutiveUnreachableProbes: Int
    ) -> Evaluation {
        switch outcome {
        case .reachable, .indeterminate:
            return Evaluation(consecutiveUnreachableProbes: 0, decision: .scheduleRetry)
        case .unreachable:
            let streak = previousConsecutiveUnreachableProbes + 1
            return Evaluation(
                consecutiveUnreachableProbes: streak,
                decision: streak >= maxConsecutiveUnreachableProbes ? .suspend : .scheduleRetry
            )
        }
    }
}

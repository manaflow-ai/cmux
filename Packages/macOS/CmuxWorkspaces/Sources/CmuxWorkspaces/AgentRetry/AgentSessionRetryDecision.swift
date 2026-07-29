/// The next state transition selected by ``AgentSessionRetryPolicy``.
public enum AgentSessionRetryDecision: Equatable, Sendable {
    /// Schedule the numbered retry after the specified delay.
    case retry(attempt: Int, maximumAttempts: Int, delaySeconds: Double)
    /// Surface exhaustion because every permitted retry was already launched.
    case exhausted(maximumAttempts: Int)
    /// Decline retry for a fail-closed classification reason.
    case reject(AgentSessionRetryRejection)
}

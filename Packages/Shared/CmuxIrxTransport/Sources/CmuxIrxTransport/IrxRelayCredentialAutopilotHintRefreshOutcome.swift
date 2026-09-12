/// Result of one bounded relay path-hint refresh probe.
enum IrxRelayCredentialAutopilotHintRefreshOutcome: Equatable {
    /// The hint was published successfully.
    case succeeded
    /// The bounded hint attempts were exhausted without a terminal auth error.
    case exhausted
    /// The broker rejected the hint for a non-retryable reason; keep the
    /// endpoint live but do not schedule an unbounded hint poll.
    case rejected
    /// The owning autopilot was cancelled or stopped.
    case stopped
}

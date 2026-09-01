/// Result of one bounded relay path-hint refresh probe.
enum IrxRelayCredentialAutopilotHintRefreshOutcome: Equatable {
    /// The hint was published successfully.
    case succeeded
    /// The bounded hint attempts were exhausted without a terminal auth error.
    case exhausted
    /// The owning autopilot was cancelled or stopped.
    case stopped
}

/// The reason a pending terminal configuration reconciliation is rolled back.
public enum TerminalConfigurationApplyAbandonReason: Equatable, Sendable {
    /// The surface still failed after the configured maximum number of attempts.
    case retryLimitReached

    /// A newer configuration snapshot replaced the pending retry.
    case pendingWorkReplaced
}

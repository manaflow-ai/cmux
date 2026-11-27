/// The broker's answer to one approve or deny attempt.
public enum SudoDecisionOutcome: Sendable, Equatable {
    /// The request left the pending phase; the authoritative snapshot follows.
    case decided

    /// The request is still pending approval, so the decision did not take
    /// effect and can be retried.
    case stillPending
}

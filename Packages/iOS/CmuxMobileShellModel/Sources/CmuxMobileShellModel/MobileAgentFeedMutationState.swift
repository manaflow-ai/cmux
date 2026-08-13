/// Client-side state for an acknowledged inline Feed mutation.
public enum MobileAgentFeedMutationState: Equatable, Sendable {
    case idle
    case sending
    /// The host accepted the mutation, but the next authoritative Feed list
    /// has not reconciled it yet. Rows stay disabled in this state.
    case awaitingReconciliation
    case failed(message: String)
}

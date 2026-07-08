/// User-initiated action predicates for Fleet task states.
public extension FleetTaskState {
    /// Indicates whether Fleet accepts a user retry from this state.
    var canUserRetry: Bool {
        switch self {
        case .failed, .cancelled, .awaitingReview:
            true
        case .queued, .provisioning, .launching, .running, .needsInput, .stalled,
             .retryBackoff, .done:
            false
        }
    }

    /// Indicates whether Fleet accepts a user cancel from this state.
    var canUserCancel: Bool {
        !isTerminal
    }
}

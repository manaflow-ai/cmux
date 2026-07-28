enum BrowserStateMutationOutcome: Equatable {
    /// The requested postcondition already holds.
    case alreadySatisfied
    /// The model changed synchronously.
    case completed
    /// The model accepted work that finishes asynchronously.
    case queued
    /// The target rejected the requested postcondition.
    case failed

    var wasAccepted: Bool {
        self != .failed
    }
}

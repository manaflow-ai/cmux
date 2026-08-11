nonisolated enum BackendOnlyFocusPointerResult: Equatable, Sendable {
    case unregistered
    case noChange
    case applied
    case rejected
    case ignoredStaleReceipt
    case actionSequenceExhausted
}

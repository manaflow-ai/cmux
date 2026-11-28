enum SudoExecutionWaitDisposition: Sendable, Equatable {
    case exited
    case authenticationFailed
    case timedOut
    case privilegedTimedOut
    case privilegedCleanupFailed
    case privilegedTransportFailed
    case failed
}

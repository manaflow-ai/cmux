enum SudoProcessOutcome: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case unavailable
    case authenticationFailed(cleanupSurvivors: [SudoProcessIdentity])
    case timedOut(cleanupSurvivors: [SudoProcessIdentity])
    case privilegedTimedOut
    case privilegedCleanupFailed(cleanupSurvivors: [SudoProcessIdentity])
    case privilegedTransportFailed
}

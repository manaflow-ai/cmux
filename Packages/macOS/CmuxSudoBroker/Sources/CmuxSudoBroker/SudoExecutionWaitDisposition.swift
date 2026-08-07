enum SudoExecutionWaitDisposition: Sendable, Equatable {
    case exited
    case authenticationFailed
    case timedOut
}

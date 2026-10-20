enum SudoExecutionRecoveryDisposition: Sendable, Equatable {
    case runnerActive
    case recovered
    case cleanupIncomplete
}

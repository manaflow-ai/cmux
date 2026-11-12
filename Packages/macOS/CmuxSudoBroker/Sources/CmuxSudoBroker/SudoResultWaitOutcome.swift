enum SudoResultWaitOutcome: Sendable, Equatable {
    case result(SudoResult)
    case timedOut(SudoCLITimeoutDisposition)
}

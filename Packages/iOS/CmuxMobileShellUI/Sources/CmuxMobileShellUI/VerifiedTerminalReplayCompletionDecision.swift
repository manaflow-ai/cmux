enum VerifiedTerminalReplayCompletionDecision: Equatable {
    case reveal
    case keepFrozenAndRequestReplay
    case ignoreStaleCompletion
}

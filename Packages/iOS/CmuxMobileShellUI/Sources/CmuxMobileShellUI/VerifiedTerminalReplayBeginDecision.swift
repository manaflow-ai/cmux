enum VerifiedTerminalReplayBeginDecision {
    case apply(VerifiedTerminalReplayTransaction)
    case keepFrozenAndRequestReplay
}

enum VerifiedTerminalReplayBeginDecision {
    case apply(VerifiedTerminalReplayTransaction)
    case keepFrozenAndRequestReplay
    /// The frame is sized for a grid that does not match this phone's current
    /// capacity and the daemon has not yet acknowledged a viewport report for
    /// the frame's epoch: keep the last verified pixels visible, request a
    /// fresh replay, and re-send the capacity report so the daemon resizes
    /// the shared PTY before anything mis-sized is presented. Emitted only on
    /// the first hold of an epoch; subsequent holds return
    /// ``keepFrozenAndRequestReplay``.
    case renegotiateViewportAndKeepFrozen
}

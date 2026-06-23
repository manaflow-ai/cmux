/// Decision produced when an authoritative replay attempt completes.
public enum TerminalSurfaceReplayCompletionDecision: Equatable, Sendable {
    /// The replay result belongs to a generation that is no longer awaiting replay.
    case ignored
    /// Replay output was delivered to the mounted surface stream.
    case delivered
    /// Replay did not deliver output; retry the specified generation if budget remains.
    case retry(generation: UInt64)
    /// Replay failed too many times; keep fallback presentation until output arrives.
    case failClosed(generation: UInt64)
}

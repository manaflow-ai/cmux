/// Result of one bounded renderer frame receive attempt.
public enum TerminalRenderFrameReceiveResult: Sendable {
    /// A completed, authenticated, generation-current IOSurface frame.
    case frame(TerminalRenderFrame)

    /// No frame arrived before the requested timeout.
    case timedOut

    /// A queued message was consumed and safely discarded.
    case dropped(TerminalRenderFrameDropReason)
}

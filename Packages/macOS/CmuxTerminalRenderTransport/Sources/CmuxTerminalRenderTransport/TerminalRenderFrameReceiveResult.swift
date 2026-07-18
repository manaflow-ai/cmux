public import CmuxTerminalRenderProtocol

/// Result of one bounded renderer frame receive attempt.
public enum TerminalRenderFrameReceiveResult: Sendable {
    /// A completed, authenticated, generation-current IOSurface frame.
    case frame(TerminalRenderFrame)

    /// No frame arrived before the requested timeout.
    case timedOut

    /// A queued message was consumed and safely discarded.
    ///
    /// `release` is present only when the sender passed capability and audit
    /// authentication, metadata decoded, and the imported IOSurface supplied an
    /// exact kernel surface ID. The host must return that lease to the worker,
    /// including when descriptor validation rejected presentation.
    case dropped(TerminalRenderFrameDropReason, release: TerminalRenderFrameRelease?)
}

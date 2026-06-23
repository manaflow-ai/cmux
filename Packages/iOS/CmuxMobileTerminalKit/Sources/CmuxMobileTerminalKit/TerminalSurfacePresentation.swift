/// User-visible presentation state derived from terminal surface lifecycle state.
public enum TerminalSurfacePresentation: Equatable, Sendable {
    /// A mounted surface has no live frame or fallback snapshot yet.
    case waitingForFirstFrame
    /// The current generation has rendered live output.
    case liveFrame
    /// No live frame is available, but a text snapshot can be shown.
    case snapshotFallback
    /// The connection is recovering while the last live frame remains visible.
    case reconnectingLiveFrame
    /// The connection is recovering and only the snapshot fallback is available.
    case reconnectingSnapshot
    /// Render recovery is in progress while the last live frame remains visible.
    case renderStalledLiveFrame
    /// Render recovery is in progress and only the snapshot fallback is available.
    case renderStalledSnapshot
    /// The surface is unavailable and no fallback can be shown.
    case unavailable
}

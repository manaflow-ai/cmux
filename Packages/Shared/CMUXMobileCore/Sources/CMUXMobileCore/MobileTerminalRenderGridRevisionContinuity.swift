/// Consumer-side chain identity of the last delivered render-grid frame.
///
/// Every emitted delta names the ``MobileTerminalRenderGridFrame/renderRevision``
/// of the frame it was diffed against (``MobileTerminalRenderGridFrame/deltaBaseRenderRevision``).
/// A consumer records this identity for each delivered frame and admits a
/// delta only when its base is exactly the delivered frame. Any dropped, shed,
/// reordered, or otherwise missed frame breaks the chain and the consumer must
/// request a full replay instead of patching a grid the producer no longer
/// models. Unlike the history-rows chain, this detects missed in-place
/// repaints, which leave the history count unchanged.
public struct MobileTerminalRenderGridRevisionContinuity: Equatable, Sendable {
    /// Producer lifetime that owns the revision sequence.
    public let renderEpoch: String
    /// Capture revision of the delivered frame.
    public let renderRevision: UInt64

    public init(renderEpoch: String, renderRevision: UInt64) {
        self.renderEpoch = renderEpoch
        self.renderRevision = renderRevision
    }

    /// The chain identity a consumer records after delivering `frame`.
    public init(delivered frame: MobileTerminalRenderGridFrame) {
        self.renderEpoch = frame.renderEpoch
        self.renderRevision = frame.renderRevision
    }

    /// Whether `frame` may patch on top of the delivered state.
    ///
    /// Full frames always pass: they replace state rather than patch it.
    /// Deltas without a base revision or without an epoch pass so the history
    /// chain remains their only guard (legacy producers omit both, and the
    /// consumer records no identity for epochless frames — rejecting them
    /// would loop replays forever). A delta that names a base must advance
    /// past it (a producer diffs against an older capture, never the same or
    /// a newer one) and passes only when `delivered` records exactly that
    /// frame; with no delivered record it fails closed.
    public static func admits(
        _ frame: MobileTerminalRenderGridFrame,
        delivered: Self?
    ) -> Bool {
        guard !frame.full, let base = frame.deltaBaseRenderRevision else { return true }
        guard !frame.renderEpoch.isEmpty else { return true }
        guard frame.renderRevision > base else { return false }
        guard let delivered else { return false }
        return delivered.renderEpoch == frame.renderEpoch
            && delivered.renderRevision == base
    }
}

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
    /// Column count of the delivered grid. A delta must address the same grid
    /// shape as its base; an unknown value cannot safely admit a delta.
    public let columns: Int?
    /// Row count of the delivered grid. A delta must address the same grid
    /// shape as its base; an unknown value cannot safely admit a delta.
    public let rows: Int?

    /// Creates a continuity record from a producer's render identity.
    ///
    /// Dimensions are optional for legacy producers, but deltas are rejected
    /// when the delivered record does not carry both values.
    public init(
        renderEpoch: String,
        renderRevision: UInt64,
        columns: Int? = nil,
        rows: Int? = nil
    ) {
        self.renderEpoch = renderEpoch
        self.renderRevision = renderRevision
        self.columns = columns
        self.rows = rows
    }

    /// The chain identity a consumer records after delivering `frame`.
    public init(delivered frame: MobileTerminalRenderGridFrame) {
        self.renderEpoch = frame.renderEpoch
        self.renderRevision = frame.renderRevision
        self.columns = frame.columns
        self.rows = frame.rows
    }

    /// How a frame relates to the delivered chain state.
    public enum Verdict: Equatable, Sendable {
        /// The frame chains exactly onto the delivered state: deliver it.
        case admit
        /// The delivered state already covers this frame (an in-flight frame
        /// from before a replay baseline landed): drop it silently. Revisions
        /// are monotonic within one epoch, so a frame at or below the
        /// delivered revision is superseded by construction, never
        /// corruption.
        case stale
        /// The chain is genuinely broken (a gap ahead, an unknown epoch, or a
        /// shape mismatch on an otherwise-linkable frame): request a replay.
        case chainBreak
    }

    /// Classifies `frame` against the delivered chain state.
    ///
    /// ``admits(_:delivered:)`` collapses this to a binary verdict; consumers
    /// that can drop superseded frames must use this instead, because
    /// answering ``Verdict/stale`` with a replay re-requests a baseline whose
    /// reset invalidates the next in-flight frames in turn — a livelock at
    /// one replay per transport round trip
    /// (https://github.com/manaflow-ai/cmux/issues/13474).
    public static func classify(
        _ frame: MobileTerminalRenderGridFrame,
        delivered: Self?
    ) -> Verdict {
        // Staleness is decidable only inside one epoch (revisions are
        // monotonic per epoch and restart across epochs) and only for frames
        // that carry a real identity. Everything else keeps the binary
        // behavior, including cross-epoch frames (fail closed) and legacy
        // epochless producers (history chain remains their only guard).
        if let delivered,
           !frame.renderEpoch.isEmpty,
           frame.renderRevision > 0,
           frame.renderEpoch == delivered.renderEpoch,
           frame.renderRevision <= delivered.renderRevision {
            return .stale
        }
        return admits(frame, delivered: delivered) ? .admit : .chainBreak
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
        guard frame.renderRevision > base else { return false }
        guard let delivered else { return false }
        // A delta with an unknown shape cannot be admitted safely. Without
        // both dimensions, a valid revision chain could still patch absolute
        // spans into a grid that changed size during a resize.
        guard delivered.columns == frame.columns,
              delivered.rows == frame.rows else { return false }
        guard delivered.renderRevision == base else { return false }
        // Legacy producers may omit the epoch, but their revision and shape
        // still have to match the delivered baseline before patching.
        guard !frame.renderEpoch.isEmpty else { return true }
        guard delivered.renderEpoch == frame.renderEpoch,
              delivered.renderRevision == base else { return false }
        return true
    }
}

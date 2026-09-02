/// Consumer-side chain identity of the last delivered render-grid frame.
///
/// Every emitted delta names the exact emission identity of the frame it was
/// diffed against (``MobileTerminalRenderGridFrame/deltaBaseEmissionRevision``).
/// A consumer records this identity for each delivered frame and admits a
/// delta only when its base is exactly the delivered frame. Any dropped, shed,
/// reordered, or otherwise missed frame breaks the chain and the consumer must
/// request a full replay instead of patching a grid the producer no longer
/// models. Unlike the history-rows chain, this detects missed in-place
/// repaints, which leave the history count unchanged.
public struct MobileTerminalRenderGridRevisionContinuity: Equatable, Sendable {
    /// Producer lifetime that owns the revision sequence.
    public let renderEpoch: String
    /// Rendered-content revision of the delivered frame.
    public let renderRevision: UInt64
    /// Exact emitted-frame identity of the delivered frame.
    public let emissionRevision: UInt64
    /// Whether ``emissionRevision`` came from an actual producer emission.
    /// Legacy and connection-projected frames can carry a content revision
    /// without an emission identity; those frames must not satisfy a delta's
    /// ``deltaBaseEmissionRevision`` check.
    public let emissionIdentityAvailable: Bool

    public init(
        renderEpoch: String,
        renderRevision: UInt64,
        emissionRevision: UInt64? = nil
    ) {
        self.renderEpoch = renderEpoch
        self.renderRevision = renderRevision
        self.emissionRevision = emissionRevision ?? renderRevision
        self.emissionIdentityAvailable = emissionRevision.map { $0 > 0 } ?? false
    }

    /// The chain identity a consumer records after delivering `frame`.
    public init(delivered frame: MobileTerminalRenderGridFrame) {
        self.renderEpoch = frame.renderEpoch
        self.renderRevision = frame.renderRevision
        self.emissionRevision = frame.emissionRevision > 0
            ? frame.emissionRevision
            : frame.renderRevision
        self.emissionIdentityAvailable = frame.emissionRevision > 0
    }

    /// Whether `frame` may patch on top of the delivered state.
    ///
    /// Full frames always pass: they replace state rather than patch it.
    /// Deltas without a base revision pass, and epochless deltas use the
    /// legacy render-revision/history chain because an emission identity cannot
    /// be authenticated across producer lifetimes. A delta that names an
    /// emission base must have a non-empty epoch and must advance past it; an
    /// epochless delta falls through to its render-revision base when present.
    /// A delta that names a base must advance past it (a producer diffs against
    /// an older capture, never the same or a newer one) and passes only when
    /// `delivered` records exactly that frame; with no delivered record it
    /// fails closed.
    public static func admits(
        _ frame: MobileTerminalRenderGridFrame,
        delivered: Self?
    ) -> Bool {
        guard !frame.full else { return true }
        if let emissionBase = frame.deltaBaseEmissionRevision {
            if frame.renderEpoch.isEmpty {
                // An epochless compatibility frame may fall through only when
                // it also carries the legacy render base. An emission-only
                // base has no producer-lifetime proof and must fail closed.
                guard frame.deltaBaseRenderRevision != nil else { return false }
            } else {
                // Epochful emission identities are exact and require a
                // delivered emitted frame from the same producer lifetime.
                guard frame.emissionRevision > emissionBase,
                      let delivered,
                      delivered.emissionIdentityAvailable else { return false }
                return delivered.renderEpoch == frame.renderEpoch
                    && delivered.emissionRevision == emissionBase
            }
        }
        guard let base = frame.deltaBaseRenderRevision else { return true }
        guard !frame.renderEpoch.isEmpty else { return true }
        guard frame.renderRevision > base else { return false }
        guard let delivered else { return false }
        return delivered.renderEpoch == frame.renderEpoch
            && delivered.renderRevision == base
    }
}

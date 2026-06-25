/// How a hosted browser web view should be re-presented in response to a batch
/// of pending update reasons during a portal sync.
///
/// The host collects free-form reason strings (e.g. `"frame"`, `"reveal"`) for a
/// single update pass, then classifies them into one outcome: do nothing, move
/// the geometry only, or run a full refresh pass. The classification is a pure
/// transform over the reason set with no app state, no AppKit view reach, and no
/// I/O, so the type lives in the browser UI package alongside the other portal
/// presentation value types and is exercised from the window host portal.
public enum HostedWebViewPresentationUpdateKind: Sendable {
    /// No presentation work is required for this update pass.
    case none
    /// Only the web view's geometry needs to be re-applied; no refresh pass.
    case geometryOnly
    /// A full refresh pass is required (reattach, reveal, anchor, recovery).
    case refresh

    /// Reasons that, on their own, require only a geometry re-apply. An update
    /// whose reasons are entirely drawn from this set resolves to `.geometryOnly`.
    private static let geometryOnlyReasons: Set<String> = [
        "frame",
        "bounds",
        "webFrame",
        "webFrameBottomDock",
    ]

    /// Reasons that force a full refresh pass. Any update touching one of these
    /// resolves to `.refresh` regardless of the other reasons present.
    private static let refreshReasons: Set<String> = [
        "syncAttachContainer",
        "syncAttachWebView",
        "reveal",
        "transientRecovery",
        "anchor",
    ]

    /// Classifies a batch of update `reasons` into the presentation outcome:
    /// `.none` for an empty batch, `.refresh` if any reason is in the refresh set
    /// or the batch is not a subset of the geometry-only set, otherwise
    /// `.geometryOnly`.
    public static func resolve(reasons: [String]) -> Self {
        guard !reasons.isEmpty else { return .none }
        let reasonSet = Set(reasons)
        if !reasonSet.isDisjoint(with: Self.refreshReasons) {
            return .refresh
        }
        if reasonSet.isSubset(of: Self.geometryOnlyReasons) {
            return .geometryOnly
        }
        return .refresh
    }
}

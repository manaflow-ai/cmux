/// Classifies a batch of hosted-web-view update reasons into the kind of
/// presentation work the portal must perform when re-syncing a webview into its
/// container.
///
/// - `none`: no reasons were supplied, so nothing needs to happen.
/// - `geometryOnly`: every reason is a pure geometry change (frame/bounds), so
///   only the webview's layout needs updating, not its rendering attachment.
/// - `refresh`: at least one reason requires a full refresh pass (reattach,
///   reveal, transient recovery, anchor), or the reasons are not a pure-geometry
///   subset, so the webview must be fully re-presented.
public enum HostedWebViewPresentationUpdateKind: Sendable, Equatable {
    case none
    case geometryOnly
    case refresh

    private static let geometryOnlyReasons: Set<String> = [
        "frame",
        "bounds",
        "webFrame",
        "webFrameBottomDock",
    ]

    private static let refreshReasons: Set<String> = [
        "syncAttachContainer",
        "syncAttachWebView",
        "reveal",
        "transientRecovery",
        "anchor",
    ]

    /// Resolves the update kind for a batch of update reasons. An empty batch is
    /// `none`; any refresh reason forces `refresh`; a batch that is purely
    /// geometry reasons is `geometryOnly`; anything else falls back to `refresh`.
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

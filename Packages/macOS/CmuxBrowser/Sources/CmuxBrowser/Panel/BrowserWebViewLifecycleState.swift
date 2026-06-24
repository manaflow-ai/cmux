/// The lifecycle phase of a browser panel's underlying ``WKWebView``.
///
/// Drives lazy realization (a `newTab`/`deferredURL` panel has no live web view
/// until shown), visibility-based suspension (`liveVisible` vs `liveHidden`),
/// and teardown (`discarded`/`closing`). The raw values are stable lifecycle
/// telemetry tokens; do not rename them.
public enum BrowserWebViewLifecycleState: String, Sendable {
    /// A new, empty tab with no pending URL and no live web view yet.
    case newTab = "new_tab"

    /// A tab with a URL queued for its first load, not yet realized.
    case deferredURL = "deferred_url"

    /// A realized web view that is currently on screen.
    case liveVisible = "live_visible"

    /// A realized web view that is off screen and may be suspended.
    case liveHidden = "live_hidden"

    /// The web view has been discarded to reclaim resources.
    case discarded

    /// The panel is tearing down.
    case closing
}

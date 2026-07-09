/// The lifecycle phase of a browser panel's backing `WKWebView`, used to drive
/// rendering, discard, and restoration decisions.
///
/// This is a pure value: the app-side `BrowserPanel` computes the next case from
/// its live WebKit/visibility state and publishes it, while consumers (debug
/// surfaces, telemetry) read the raw string. The raw values are wire-stable and
/// must not change.
public enum BrowserWebViewLifecycleState: String, Sendable, Equatable {
    /// A fresh tab with no committed URL yet.
    case newTab = "new_tab"
    /// A tab carrying a deferred URL that has not yet been loaded into a web view.
    case deferredURL = "deferred_url"
    /// The web view is live and currently visible in the UI.
    case liveVisible = "live_visible"
    /// The web view is live but hidden (offscreen / backgrounded).
    case liveHidden = "live_hidden"
    /// The web view was discarded to reclaim memory and can be reconstructed.
    case discarded
    /// The panel is tearing its web view lifecycle down.
    case closing
}

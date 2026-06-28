public import Foundation

/// The app-side seam ``BrowserFaviconCoordinator`` drives for the favicon-refresh
/// effects it cannot own from the package. `BrowserPanel` conforms.
///
/// The coordinator owns the refresh state machine (generation/sequencing, the
/// SPA retry-once, the skip-cached-URL flow) but every effect that touches the
/// live `WKWebView`, the remote-proxy `URLSession`, or the panel's `@Published`
/// favicon bytes is forwarded through this host. The host evaluates the favicon
/// discovery script in the page, fetches the icon bytes (applying the
/// remote-proxy URL rewrite and session selection), and publishes the rendered
/// PNG; the coordinator never sees the web view or the proxy session.
///
/// `@MainActor` because every effect is one main-actor turn driven by a WebKit
/// navigation callback, and the host (`BrowserPanel`) lives on main, so
/// forwarding stays a plain call with no bridging.
@MainActor
public protocol BrowserFaviconHosting: AnyObject {
    /// The current page URL (`webView.url`) at the moment a refresh begins. The
    /// coordinator captures it once to drive scheme gating, the `/favicon.ico`
    /// fallback, and the begin/iconURL debug logs.
    var currentFaviconPageURL: URL? { get }

    /// The current web view instance id (`webViewInstanceID`), captured at refresh
    /// start so each subsequent ``isCurrentFaviconWebView(instanceID:)`` check can
    /// detect a web-view swap that invalidates the in-flight refresh.
    var currentFaviconWebViewInstanceID: UUID { get }

    /// Whether the captured `instanceID` still matches the live web view (legacy
    /// `isCurrentWebView(webView, instanceID:)`). Returns `false` once the panel
    /// has swapped its web view out from under the refresh.
    func isCurrentFaviconWebView(instanceID: UUID) -> Bool

    /// Evaluates the favicon discovery script (``BrowserFaviconDiscoveryScript/source``)
    /// in the live web view with the 400 ms timeout and returns the raw `href`
    /// string, or `nil` on timeout/failure. The live `evaluateJavaScript` call
    /// stays app-side; the coordinator parses the result.
    func evaluateFaviconDiscoveryScript() async -> String?

    /// Whether a favicon PNG is already published (`faviconPNGData != nil`), read
    /// by the skip-cached check so an unchanged icon URL avoids a refetch.
    var hasFaviconPNGData: Bool { get }

    /// Fetches the favicon bytes for `request`, applying the remote-proxy URL
    /// rewrite and choosing the remote-proxy `URLSession` or `URLSession.shared`
    /// (legacy `remoteProxyPreparedRequest(from:logScope:)` +
    /// `remoteProxyURLSession()`), then returns the body and response, or `nil`
    /// when the fetch throws. The live proxy session never crosses the seam.
    func fetchFaviconData(request: URLRequest) async -> (Data, URLResponse)?

    /// Publishes the rendered favicon PNG, setting the panel's `@Published`
    /// `faviconPNGData` (legacy `faviconPNGData = png`).
    func publishFaviconPNG(_ png: Data)
}

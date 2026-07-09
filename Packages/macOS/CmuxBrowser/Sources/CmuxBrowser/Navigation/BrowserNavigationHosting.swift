public import Foundation

/// The app-side seam ``BrowserNavigationIntentCoordinator`` drives for the
/// navigation effects it cannot own from the package. `BrowserPanel` conforms.
///
/// The coordinator owns the insecure-HTTP block/bypass decision and the pending
/// one-time bypass host, then forwards each resolved effect through the host:
/// loading a request in the current tab, opening a sibling tab, opening a URL in
/// the system default browser, or presenting the app's 3-button insecure-HTTP
/// alert. The alert's `String(localized:)` strings stay app-side so they bind to
/// the app bundle's `.xcstrings`, preserving translations (mirroring
/// ``BrowserPopupNavigationHosting``).
///
/// `@MainActor` because every effect is one main-actor turn driven by a WebKit
/// navigation callback or omnibar action, and the host (`BrowserPanel`) lives on
/// main, so forwarding stays a plain call with no bridging.
@MainActor
public protocol BrowserNavigationHosting: AnyObject {
    /// Whether this surface is backed by a remote-workspace proxy (read-through
    /// of the panel's `usesRemoteWorkspaceProxy`). Drives the queue-vs-perform
    /// decision in ``BrowserNavigationIntentCoordinator``.
    var usesRemoteWorkspaceProxy: Bool { get }

    /// Whether the remote-workspace proxy endpoint is available yet (read-through
    /// of the panel's `remoteProxyEndpoint != nil`). The endpoint type stays
    /// panel-owned with its many cross-domain readers; only this nil-check is
    /// exposed.
    var hasRemoteProxyEndpoint: Bool { get }

    /// Resets the hidden-web-view discard state before a navigation begins
    /// (legacy `cancelHiddenWebViewDiscard()` + `clearWebViewDiscardState(reason:)`).
    func prepareWebViewDiscardStateForNavigation()

    /// Reconsiders whether the hidden web view should be scheduled for discard
    /// (legacy `reevaluateHiddenWebViewDiscardScheduling(reason:)`), used when a
    /// stranded pending navigation is cleared.
    func reevaluateHiddenWebViewDiscardScheduling(reason: String)

    /// Sets the URL shown for the current surface while a navigation is queued
    /// behind a remote-proxy endpoint (legacy `currentURL = …`).
    func setCurrentDisplayURL(_ url: URL)

    /// Applies the placeholder render intent for a navigation queued behind a
    /// pending remote-proxy endpoint: clears the restored-session render intent,
    /// records `url` as the last attempted URL, refreshes the background, and
    /// forces the web view to render without loading.
    func setRenderIntent(forQueuedRemoteNavigationAttempting url: URL)

    /// Performs an immediate navigation in the current tab once any queue gate
    /// has cleared (legacy `performNavigation(request:originalURL:…)`). The web
    /// view load, custom user agent, typed-navigation history record, and
    /// background refresh stay app-side as the host witness.
    func performNavigation(
        request: URLRequest,
        originalURL: URL,
        recordTypedNavigation: Bool,
        preserveRestoredSessionHistory: Bool
    )

    /// Loads `request` in the current tab's web view without re-running the
    /// insecure-HTTP prompt (legacy `navigateWithoutInsecureHTTPPrompt(request:recordTypedNavigation:)`).
    func loadRequestInCurrentTab(_ request: URLRequest, recordTypedNavigation: Bool)

    /// Opens `request` in a sibling browser surface, granting
    /// `bypassInsecureHTTPHostOnce` (when non-nil) a one-time insecure-HTTP bypass
    /// on the new surface (legacy `openLinkInNewTab(request:bypassInsecureHTTPHostOnce:)`).
    func openLinkInNewTab(request: URLRequest, bypassInsecureHTTPHostOnce: String?)

    /// Opens `url` in the system default browser (legacy `NSWorkspace.shared.open`).
    func openURLInDefaultBrowser(_ url: URL)

    /// Presents the app's insecure-HTTP warning alert for `request`, resolving the
    /// user's choice back through
    /// ``BrowserNavigationIntentCoordinator/resolveAlertResponse(_:suppressionEnabled:host:request:url:intent:recordTypedNavigation:)``.
    func presentInsecureHTTPAlert(
        for request: URLRequest,
        intent: BrowserInsecureHTTPNavigationIntent,
        recordTypedNavigation: Bool
    )
}

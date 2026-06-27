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

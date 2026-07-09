public import Foundation

/// The app-side seam ``BrowserSessionHistoryCoordinator`` drives for the live
/// WebKit and navigation-availability state it cannot own from the package.
/// `BrowserPanel` conforms.
///
/// The coordinator owns the pure ``RestoredSessionHistory`` value and decides how
/// it reconciles against live navigation, but every input it needs (the native
/// WebKit `canGoBack`/`canGoForward` flags, the native back-forward URL lists, and
/// the display-rewritten resolved live/current URLs from the slice-1
/// ``BrowserSessionHistoryURLResolver``) and every effect it produces (publishing
/// the resolved availability, issuing a restored-history navigation, and the
/// `#if DEBUG` forward-clear log that names the panel id) stay app-side behind
/// this seam, so the live `WKWebView` and the panel's `@Published` state never
/// cross into the package.
///
/// `@MainActor` because the host (`BrowserPanel`) lives on main and every entry
/// point runs on a main-actor WebKit/omnibar turn, so forwarding stays a plain
/// call with no bridging (mirroring ``BrowserNavigationHosting``).
@MainActor
public protocol BrowserSessionHistoryHosting: AnyObject {
    /// WebKit's live `canGoBack` for the current web view.
    var nativeCanGoBack: Bool { get }

    /// WebKit's live `canGoForward` for the current web view.
    var nativeCanGoForward: Bool { get }

    /// The live `backForwardList.backList` URLs, oldest first.
    var nativeBackForwardBackURLs: [URL] { get }

    /// The live `backForwardList.forwardList` URLs.
    var nativeBackForwardForwardURLs: [URL] { get }

    /// The resolved live session-history URL: the display-rewritten live web-view
    /// URL when serializable, otherwise the current URL when serializable,
    /// otherwise `nil` (slice-1 ``BrowserSessionHistoryURLResolver/resolvedLiveURL(webViewDisplayURL:currentURL:)``).
    func resolvedLiveSessionHistoryURL() -> URL?

    /// The resolved current session-history URL, falling back to the restored
    /// current URL (slice-1 ``BrowserSessionHistoryURLResolver/resolvedCurrentURL(webViewDisplayURL:currentURL:restoredCurrentURL:)``).
    func resolvedCurrentSessionHistoryURL() -> URL?

    /// Publishes the resolved back/forward availability onto the surface's
    /// `@Published canGoBack`/`canGoForward`, assigning only on change.
    func setNavigationAvailability(canGoBack: Bool, canGoForward: Bool)

    /// Issues a restored-history navigation to `url`, replaying it as a non-typed,
    /// restored-session-history-preserving load
    /// (legacy `navigateWithoutInsecureHTTPPrompt(to:recordTypedNavigation:false,preserveRestoredSessionHistory:true)`).
    func navigate(toRestoredSessionHistoryURL url: URL)

    /// Emits the `#if DEBUG` forward-clear debug log (host-side so the string binds
    /// to the app and can name the panel id), invoked when the restored forward
    /// stack is cleared because the live current entry was not found in either
    /// stack. A no-op in release builds.
    func logRestoredSessionHistoryForwardClear(liveCurrentString: String)
}

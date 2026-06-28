public import Foundation

/// The policy the main browser surface should apply to a top-level
/// `WKNavigationAction`, classified purely from the action's request, frame,
/// gesture, and download intent.
///
/// The classification is a stateless transform: it reads the request URL, the
/// main-frame flag, whether the target frame is `nil`, the insecure-HTTP block
/// rule (supplied as a closure so the app-side allowlist check stays app-side
/// and runs only when reached), whether a cmd/middle-click gesture should open a
/// new tab (``BrowserUserGestureNavigation/opensInNewTab``), whether a
/// `nil`-target navigation of this type falls back to a new tab
/// (``WKNavigationType/fallsBackNilTargetToNewTab``), and the external-scheme
/// routing rule (``BrowserExternalNavigationAction``). It never reads live
/// WebKit, window, or delegate state. The owning `WKNavigationDelegate` extracts
/// those primitives, calls ``resolve(request:isMainFrame:targetFrameIsNil:shouldBlockInsecureHTTP:shouldOpenInNewTab:fallsBackNilTargetToNewTab:shouldPerformDownload:)``,
/// and performs the resolved hand-off (insecure-HTTP routing, external routing,
/// new-tab open, `decisionHandler` call), which stays app-side.
public enum BrowserMainFrameNavigationActionDecision: Sendable, Equatable {
    /// Hand the blocked insecure-HTTP navigation to the app's intent coordinator
    /// with the resolved destination, then cancel the in-page navigation.
    case blockedInsecureHTTP(intent: BrowserInsecureHTTPNavigationIntent)

    /// Hand `url` off for external routing (deeplink / native app), then cancel
    /// the in-page navigation.
    case routeExternally(URL)

    /// Treat the navigation as a download (`decisionHandler(.download)`).
    case download

    /// Open `request` in a new tab because of a cmd/middle-click gesture, then
    /// cancel the in-page navigation.
    case openInNewTab(URLRequest)

    /// Open `request` in a new tab because it is a `target=_blank`-style
    /// `nil`-target navigation that falls back to a new tab, then cancel the
    /// in-page navigation.
    case openInNewTabFromNilTarget(URLRequest)

    /// Allow the navigation to proceed (`decisionHandler(.allow)`). `lastAttemptedURL`
    /// is the request URL the delegate records as the last attempted navigation
    /// when the action targets the main frame.
    case allow(lastAttemptedURL: URL?)

    /// Classifies the policy for a main-frame navigation action.
    ///
    /// The branch order is significant and matches the main browser navigation
    /// delegate: blocked-insecure-HTTP, then external routing, then the download
    /// flag, then the cmd/middle-click new-tab gesture, then the `nil`-target
    /// new-tab fallback, then allow.
    ///
    /// - Parameters:
    ///   - request: The navigation action's request.
    ///   - isMainFrame: Whether the action targets the main frame
    ///     (`navigationAction.targetFrame?.isMainFrame != false`).
    ///   - targetFrameIsNil: Whether the action has no target frame
    ///     (`navigationAction.targetFrame == nil`).
    ///   - shouldBlockInsecureHTTP: Whether the request URL should be blocked as
    ///     insecure HTTP. Evaluated lazily, only when the request has a URL and
    ///     the action targets the main frame, so the app-side allowlist check
    ///     runs only when reached.
    ///   - shouldOpenInNewTab: Whether the gesture forces a new tab
    ///     (``BrowserUserGestureNavigation/opensInNewTab``).
    ///   - fallsBackNilTargetToNewTab: Whether a `nil`-target navigation of this
    ///     type falls back to a new tab
    ///     (``WKNavigationType/fallsBackNilTargetToNewTab``).
    ///   - shouldPerformDownload: Whether WebKit flagged the action as a download
    ///     (`navigationAction.shouldPerformDownload`).
    /// - Returns: The decision the delegate should apply.
    public static func resolve(
        request: URLRequest,
        isMainFrame: Bool,
        targetFrameIsNil: Bool,
        shouldBlockInsecureHTTP: (URL) -> Bool,
        shouldOpenInNewTab: Bool,
        fallsBackNilTargetToNewTab: Bool,
        shouldPerformDownload: Bool
    ) -> BrowserMainFrameNavigationActionDecision {
        let url = request.url

        if let url, isMainFrame, shouldBlockInsecureHTTP(url) {
            let intent: BrowserInsecureHTTPNavigationIntent =
                (shouldOpenInNewTab || targetFrameIsNil) ? .newTab : .currentTab
            return .blockedInsecureHTTP(intent: intent)
        }

        if let url, BrowserExternalNavigationAction.shouldRoute(url) {
            return .routeExternally(url)
        }

        if shouldPerformDownload {
            return .download
        }

        if shouldOpenInNewTab, request.url != nil {
            return .openInNewTab(request)
        }

        if targetFrameIsNil, fallsBackNilTargetToNewTab, request.url != nil {
            return .openInNewTabFromNilTarget(request)
        }

        return .allow(lastAttemptedURL: url)
    }
}

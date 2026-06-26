public import Foundation

/// The policy a browser popup window should apply to a scripted-`window.open`
/// popup's `WKNavigationAction`, classified purely from the action's URL, frame,
/// and download intent.
///
/// The classification is a stateless transform: it reads the candidate URL, the
/// external-scheme routing rule (``BrowserExternalNavigationAction``), the
/// insecure-HTTP allowlist (``BrowserInsecureHTTPSettings``), whether the
/// navigation targets the main frame, and whether WebKit flagged it as a
/// download, never any live WebKit, window, or delegate state. The popup's
/// `WKNavigationDelegate` extracts those primitives, calls ``resolve(url:isMainFrame:shouldPerformDownload:insecureHTTPDefaults:)``,
/// and performs the actual hand-off (external routing, insecure-HTTP prompt, or
/// `decisionHandler` call), which stays app-side.
public enum PopupNavigationActionDecision: Sendable, Equatable {
    /// Allow the navigation to proceed (`decisionHandler(.allow)`). Covers a
    /// missing URL, a non-main-frame navigation, and the default case.
    case allow

    /// Hand `url` off for external routing, then cancel the in-page navigation.
    case routeExternally(URL)

    /// Present the insecure-HTTP prompt for `url` before deciding the policy.
    case promptInsecureHTTP(URL)

    /// Treat the navigation as a download (`decisionHandler(.download)`).
    case download

    /// Classifies the policy for a popup navigation action.
    ///
    /// The branch order is significant and matches the popup navigation delegate:
    /// external routing is checked before the main-frame guard, and the
    /// insecure-HTTP prompt is checked before the download flag.
    ///
    /// - Parameters:
    ///   - url: The navigation action's request URL, if any.
    ///   - isMainFrame: Whether the action targets the main frame
    ///     (`navigationAction.targetFrame?.isMainFrame != false`).
    ///   - shouldPerformDownload: Whether WebKit flagged the action as a download
    ///     (`navigationAction.shouldPerformDownload`).
    ///   - insecureHTTPDefaults: The defaults backing the insecure-HTTP allowlist.
    /// - Returns: The decision the delegate should apply.
    public static func resolve(
        url: URL?,
        isMainFrame: Bool,
        shouldPerformDownload: Bool,
        insecureHTTPDefaults: UserDefaults = .standard
    ) -> PopupNavigationActionDecision {
        guard let url else { return .allow }

        if BrowserExternalNavigationAction.shouldRoute(url) {
            return .routeExternally(url)
        }

        guard isMainFrame else { return .allow }

        if BrowserInsecureHTTPSettings.shouldBlock(url, defaults: insecureHTTPDefaults) {
            return .promptInsecureHTTP(url)
        }

        if shouldPerformDownload {
            return .download
        }

        return .allow
    }
}

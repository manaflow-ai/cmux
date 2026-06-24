public import Foundation

/// Classifies whether the browser is currently showing a blank (`about:blank`)
/// page, reconciling the live web-view URL, the model's current URL, and any
/// in-flight provisional navigation.
///
/// A blank page is one whose effective URL is empty or `about:blank`
/// (case-insensitive, surrounding whitespace ignored). The combined predicate
/// treats an active provisional navigation toward a non-blank destination as
/// "not blank" so the chrome does not briefly render the blank-page treatment
/// while a real page is loading.
public struct BrowserBlankPageClassifier: Sendable {
    public init() {}

    /// Whether a single URL points at the blank page. A `nil` URL counts as
    /// blank.
    public func isBlankBrowserPageURL(_ url: URL?) -> Bool {
        guard let url else { return true }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.caseInsensitiveCompare("about:blank") == .orderedSame
    }

    /// Whether the browser is showing the blank page given the live web-view
    /// URL, the model's current URL, the pending navigation URL, and whether a
    /// main-frame provisional navigation is active.
    public func isBlankBrowserPage(
        liveURL: URL?,
        currentURL: URL?,
        pendingNavigationURL: URL?,
        isMainFrameProvisionalNavigationActive: Bool
    ) -> Bool {
        if isMainFrameProvisionalNavigationActive,
           !isBlankBrowserPageURL(pendingNavigationURL) {
            return false
        }
        if !isBlankBrowserPageURL(pendingNavigationURL),
           isBlankBrowserPageURL(liveURL),
           isBlankBrowserPageURL(currentURL) {
            return false
        }
        return isBlankBrowserPageURL(liveURL) && isBlankBrowserPageURL(currentURL)
    }
}

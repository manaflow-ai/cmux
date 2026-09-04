public import Foundation

/// A navigation request awaiting cmux policy evaluation.
public struct BrowserEngineNavigationRequest: Sendable {
    /// The URL request emitted by the browser engine.
    public let request: URLRequest

    /// The destination requested by the page.
    public let disposition: BrowserEngineNavigationDisposition

    /// Whether the engine reported an explicit user gesture for this request.
    /// Engines that cannot provide that signal leave this `false`, which keeps
    /// security-sensitive policies fail-closed.
    public let isUserInitiated: Bool

    /// Whether the engine identified this request as a redirect.
    public let isRedirect: Bool

    /// Whether the request came from a new-window/new-tab callback rather
    /// than the current document's ordinary main-frame navigation.
    public let isPopupNavigation: Bool

    /// The page that initiated the request, when the engine can report it.
    /// This is used to constrain app-owned callback URLs to a trusted origin.
    public let sourceURL: URL?

    /// Creates a navigation policy request.
    ///
    /// - Parameters:
    ///   - request: The original engine request.
    ///   - disposition: Whether the page requested the current tab or a new tab.
    ///   - isUserInitiated: Whether the engine observed an explicit user gesture.
    ///   - sourceURL: The initiating page URL, when available.
    ///   - isRedirect: Whether the request is a redirect.
    ///   - isPopupNavigation: Whether the request came from a popup/special-tab callback.
    public init(
        request: URLRequest,
        disposition: BrowserEngineNavigationDisposition,
        isUserInitiated: Bool = false,
        sourceURL: URL? = nil,
        isRedirect: Bool = false,
        isPopupNavigation: Bool = false
    ) {
        self.request = request
        self.disposition = disposition
        self.isUserInitiated = isUserInitiated
        self.sourceURL = sourceURL
        self.isRedirect = isRedirect
        self.isPopupNavigation = isPopupNavigation
    }
}

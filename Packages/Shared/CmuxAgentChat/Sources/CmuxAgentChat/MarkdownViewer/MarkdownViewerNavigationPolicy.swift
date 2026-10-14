import Foundation

/// What the markdown viewer's WebView does with a navigation request.
public enum MarkdownViewerNavigationDecision: Equatable, Sendable {
    /// Let WebKit perform the navigation in place.
    case allow
    /// Cancel in WebKit and hand the URL to the host's link router.
    case openExternally(URL)
    /// Cancel without side effects.
    case cancel
}

/// Navigation policy shared by the macOS and iOS markdown viewer coordinators.
///
/// The viewer document is the shell the host loads itself. After that, only
/// two kinds of navigation are honored: same-document fragment jumps, and
/// links the user activated, which leave through the host router. Script
/// driven navigations, form submissions, reloads, and subframe loads are all
/// cancelled, so rendered content cannot move the privileged view elsewhere
/// or open URLs without a click.
public struct MarkdownViewerNavigationPolicy: Sendable {
    public init() {}

    /// - Parameters:
    ///   - url: The navigation request URL.
    ///   - isUserLinkActivation: WebKit reported `WKNavigationType.linkActivated`.
    ///   - isMainFrame: The target frame is the main frame.
    ///   - isInPageFragment: The URL is a fragment of the current document.
    ///   - isShellDocumentLoad: The host is loading its shell and `url` is the
    ///     shell's base URL (see `isShellDocumentURL`).
    public func decide(
        url: URL?,
        isUserLinkActivation: Bool,
        isMainFrame: Bool,
        isInPageFragment: Bool,
        isShellDocumentLoad: Bool
    ) -> MarkdownViewerNavigationDecision {
        guard let url else { return .cancel }
        if isInPageFragment && isMainFrame {
            return .allow
        }
        if isUserLinkActivation {
            return .openExternally(url)
        }
        if isShellDocumentLoad && isMainFrame {
            return .allow
        }
        return .cancel
    }

    /// Whether `url` is the request WebKit issues for
    /// `loadHTMLString(_:baseURL: shellBaseURL)`.
    public func isShellDocumentURL(_ url: URL, shellBaseURL: URL?) -> Bool {
        guard let shellBaseURL else {
            return url.absoluteString == "about:blank"
        }
        return Self.withoutFragment(url) == Self.withoutFragment(shellBaseURL)
    }

    private static func withoutFragment(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}

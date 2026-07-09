/// The policy the main browser surface should apply to a top-level
/// `WKNavigationResponse`, classified purely from the response's frame, URL
/// scheme, and download intent.
///
/// The classification is a stateless transform over three primitives the main
/// `WKNavigationDelegate` extracts from the response: whether it targets the main
/// frame, the response URL's scheme, and whether the response should be treated
/// as a download. It never reads live WebKit, window, or delegate state. The
/// download determination itself stays app-side (it consults the app's
/// download-filename resolver, ``BrowserDownloadFilenameResolver``), so it is
/// supplied as the `isDownload` closure, which the classifier invokes only when
/// it reaches the download branch, preserving the delegate's original evaluation
/// order: the resolver runs only after the main-frame and scheme guards pass.
///
/// This mirrors ``PopupNavigationResponseDecision`` but is a distinct type for
/// the main browser surface, whose delegate interleaves additional app-side
/// logging around the download branch.
public enum BrowserMainFrameNavigationResponseDecision: Sendable, Equatable {
    /// Allow the response to proceed (`decisionHandler(.allow)`). Covers a
    /// non-main-frame response, a non-HTTP(S) scheme, and the default case.
    case allow

    /// Treat the response as a download (`decisionHandler(.download)`).
    case download

    /// Classifies the policy for a main-frame navigation response.
    ///
    /// The branch order matches the main browser navigation delegate: the
    /// non-main-frame guard is checked first, then the non-HTTP(S) scheme guard,
    /// then the download determination. The scheme is compared case-insensitively
    /// against `http` and `https`.
    ///
    /// - Parameters:
    ///   - isForMainFrame: Whether the response targets the main frame
    ///     (`navigationResponse.isForMainFrame`).
    ///   - scheme: The response URL's scheme, if any
    ///     (`navigationResponse.response.url?.scheme`).
    ///   - isDownload: Whether the response should be treated as a download.
    ///     Evaluated lazily, only when the main-frame and scheme guards pass.
    /// - Returns: The decision the delegate should apply.
    public static func resolve(
        isForMainFrame: Bool,
        scheme: String?,
        isDownload: () -> Bool
    ) -> BrowserMainFrameNavigationResponseDecision {
        if !isForMainFrame {
            return .allow
        }

        if let scheme = scheme?.lowercased(), scheme != "http", scheme != "https" {
            return .allow
        }

        if isDownload() {
            return .download
        }

        return .allow
    }
}

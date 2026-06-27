public import Foundation

/// Resolves which URL (or serialized string) a browser surface should report for
/// session-history persistence, replay, and snapshotting.
///
/// The decision rules layer over ``SessionHistoryURLSanitizer``: a candidate URL
/// is preferred only when it serializes to an eligible history string (non-empty,
/// not `about:blank`, not a temporary diff-viewer or remote-loopback alias URL).
/// Every input URL is supplied already rewritten for display, so the resolver
/// touches no `WKWebView` or back-forward-list state. The owning surface passes
/// in the proxy-display-rewritten live URL, the current URL, and the restored
/// current URL; the resolver picks among them.
public struct BrowserSessionHistoryURLResolver: Sendable {
    private let sanitizer: SessionHistoryURLSanitizer

    /// Creates a resolver wrapping a sanitizer.
    ///
    /// - Parameter sanitizer: The session-history URL sanitizer whose eligibility
    ///   rules govern which candidate URLs are preferred.
    public init(sanitizer: SessionHistoryURLSanitizer) {
        self.sanitizer = sanitizer
    }

    /// Returns whether a URL is a transient session-history URL.
    public func isTemporarySessionHistoryURL(_ url: URL?) -> Bool {
        sanitizer.isTemporarySessionHistoryURL(url)
    }

    /// Returns the serialized history string for a URL, or `nil` when the URL is
    /// not eligible for session-history persistence.
    public func serializableSessionHistoryURLString(_ url: URL?) -> String? {
        sanitizer.serializableSessionHistoryURLString(url)
    }

    /// Parses a stored history string into an eligible URL, or `nil` when the
    /// string is empty, `about:blank`, unparseable, or temporary.
    public func sanitizedSessionHistoryURL(_ raw: String?) -> URL? {
        sanitizer.sanitizedSessionHistoryURL(raw)
    }

    /// Maps a list of stored history strings to eligible URLs, dropping any that
    /// fail ``sanitizedSessionHistoryURL(_:)``.
    public func sanitizedSessionHistoryURLs(_ values: [String]) -> [URL] {
        sanitizer.sanitizedSessionHistoryURLs(values)
    }

    /// Resolves the live session-history URL: the display-rewritten live URL when
    /// it is serializable, otherwise the current URL when it is serializable,
    /// otherwise `nil`.
    ///
    /// - Parameters:
    ///   - webViewDisplayURL: The live web-view URL, already rewritten for display.
    ///   - currentURL: The surface's current URL.
    public func resolvedLiveURL(webViewDisplayURL: URL?, currentURL: URL?) -> URL? {
        if let webViewDisplayURL,
           sanitizer.serializableSessionHistoryURLString(webViewDisplayURL) != nil {
            return webViewDisplayURL
        }
        if let currentURL,
           sanitizer.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return nil
    }

    /// Resolves the current session-history URL: the display-rewritten live URL
    /// when serializable, otherwise the current URL when serializable, otherwise
    /// the restored current URL as a fallback.
    ///
    /// - Parameters:
    ///   - webViewDisplayURL: The live web-view URL, already rewritten for display.
    ///   - currentURL: The surface's current URL.
    ///   - restoredCurrentURL: The restored-session-history current URL fallback.
    public func resolvedCurrentURL(
        webViewDisplayURL: URL?,
        currentURL: URL?,
        restoredCurrentURL: URL?
    ) -> URL? {
        if let webViewDisplayURL,
           sanitizer.serializableSessionHistoryURLString(webViewDisplayURL) != nil {
            return webViewDisplayURL
        }
        if let currentURL,
           sanitizer.serializableSessionHistoryURLString(currentURL) != nil {
            return currentURL
        }
        return restoredCurrentURL
    }

    /// Resolves the preferred URL string for a session snapshot: the serialized
    /// display-rewritten live URL when eligible, otherwise the serialized current
    /// URL when eligible, otherwise `nil`.
    ///
    /// - Parameters:
    ///   - webViewDisplayURL: The live web-view URL, already rewritten for display.
    ///   - currentURL: The surface's current URL.
    public func preferredURLString(webViewDisplayURL: URL?, currentURL: URL?) -> String? {
        if let webViewDisplayURL,
           let value = sanitizer.serializableSessionHistoryURLString(webViewDisplayURL) {
            return value
        }
        if let currentURL,
           let value = sanitizer.serializableSessionHistoryURLString(currentURL) {
            return value
        }
        return nil
    }
}

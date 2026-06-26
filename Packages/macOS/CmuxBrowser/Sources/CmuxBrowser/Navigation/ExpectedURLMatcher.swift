public import Foundation

/// Compares a web view's current URL against an expected absolute URL string,
/// tolerating the normalization differences that do not change identity.
///
/// A screenshot waiter polls a `WKWebView` until its URL settles on the URL it
/// was asked to capture. A literal string equality is too strict: the live URL
/// and the requested URL can differ only in scheme/host case, a trailing path
/// slash, or an implicit default port (80 for `http`, 443 for `https`) while
/// still pointing at the same resource. This matcher applies exactly those
/// tolerances. Query and fragment are compared only when the expected URL
/// specifies them, so an expected URL without a query/fragment matches a live
/// URL that carries one.
public struct ExpectedURLMatcher: Sendable {
    private let expectedAbsoluteString: String

    /// Creates a matcher for one expected absolute URL string.
    public init(expectedAbsoluteString: String) {
        self.expectedAbsoluteString = expectedAbsoluteString
    }

    /// Returns whether `currentURL` is equivalent to the expected URL under the
    /// scheme/host-case, trailing-slash, and default-port tolerances.
    public func matches(_ currentURL: URL) -> Bool {
        let currentAbsoluteString = currentURL.absoluteString
        if currentAbsoluteString == expectedAbsoluteString {
            return true
        }

        guard
            var expected = URLComponents(string: expectedAbsoluteString),
            var current = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
        else {
            return false
        }

        expected.scheme = expected.scheme?.lowercased()
        current.scheme = current.scheme?.lowercased()
        expected.host = expected.host?.lowercased()
        current.host = current.host?.lowercased()

        let expectedPath = Self.normalizedPathComponent(expected.path)
        let currentPath = Self.normalizedPathComponent(current.path)
        let expectedPort = Self.normalizedPortComponent(expected.port, scheme: expected.scheme)
        let currentPort = Self.normalizedPortComponent(current.port, scheme: current.scheme)
        guard expected.scheme == current.scheme,
              expected.host == current.host,
              expectedPort == currentPort,
              expectedPath == currentPath else {
            return false
        }

        if expected.query != nil, expected.query != current.query {
            return false
        }
        if expected.fragment != nil, expected.fragment != current.fragment {
            return false
        }
        return true
    }

    private static func normalizedPathComponent(_ path: String) -> String {
        if path == "/" {
            return ""
        }
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func normalizedPortComponent(_ port: Int?, scheme: String?) -> Int? {
        if let port {
            return port
        }
        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}

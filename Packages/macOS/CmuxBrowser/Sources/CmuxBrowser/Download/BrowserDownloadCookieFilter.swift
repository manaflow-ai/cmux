public import Foundation

/// RFC-6265-style cookie-attribute filtering for the browser context-menu
/// download path.
///
/// Lifted byte-faithfully out of the app-target `CmuxWebView` so that the
/// secure/expiry/domain/path predicates that decide which of a `WKHTTPCookieStore`'s
/// cookies belong on a download `URLRequest` live in `CmuxBrowser` beside
/// `BrowserDownloadURLClassifier` and `BrowserDownloadFilenameResolver`.
///
/// `filter(_:url:)` is a deterministic transform over the cookie list and the
/// request URL's scheme/host/path with zero instance state, so this is a pure
/// value type, not a static-only namespace of utilities: callers construct
/// `BrowserDownloadCookieFilter()` and call `filter(cookies, url: url)`. A pure
/// value type with no stored state, so it is `Sendable` and `nonisolated`.
public nonisolated struct BrowserDownloadCookieFilter: Sendable {
    /// Creates a cookie filter.
    public init() {}

    /// The subset of `cookies` that should be sent on a download request to `url`,
    /// applying secure-channel, expiry, domain-match, and path-match rules.
    public func filter(_ cookies: [HTTPCookie], url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.caseInsensitiveCompare("https") == .orderedSame
        let now = Date.now

        return cookies.filter { cookie in
            if cookie.isSecure && !isHTTPS { return false }
            if let expires = cookie.expiresDate, expires <= now { return false }
            guard domain(cookie.domain, matches: host) else { return false }
            return path(cookie.path, matches: requestPath)
        }
    }

    /// Whether `cookieDomain` matches request `host` per RFC-6265 domain-match
    /// rules (leading-dot cookies match the host and any subdomain; host-only
    /// cookies match the host exactly).
    private func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let normalized = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !normalized.isEmpty else { return false }
        if cookieDomain.hasPrefix(".") {
            return host == normalized || host.hasSuffix(".\(normalized)")
        }
        return host == normalized
    }

    /// Whether `cookiePath` is a path-match prefix of the request `requestPath`
    /// per RFC-6265 path-match rules.
    private func path(_ cookiePath: String, matches requestPath: String) -> Bool {
        let normalized = cookiePath.isEmpty ? "/" : cookiePath
        if normalized == "/" || requestPath == normalized { return true }
        guard requestPath.hasPrefix(normalized) else { return false }
        return normalized.hasSuffix("/") || requestPath.dropFirst(normalized.count).first == "/"
    }
}

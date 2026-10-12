public import Foundation

/// Which of a tab's cookies go with a URL, for the driver's `cookies.get`
/// URL filter and so for the cookies the REPL's `fetch` sends.
extension HTTPCookie {
    /// Whether this cookie goes with a request to `url`: domain and path
    /// match, and a Secure cookie only on https or a loopback host.
    public func browserReplMatches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = self.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bare || host.hasSuffix("." + bare) else { return false }
        // The path as sent, trailing slash kept (`URL.path` drops it).
        let sent = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard Self.browserReplPath(sent.hasPrefix("/") ? sent : "/", matches: path) else { return false }
        return !isSecure || url.scheme == "https" || Self.browserReplIsLoopback(host)
    }

    /// RFC 6265 section 5.1.4 path-match: the cookie path is the request path,
    /// or a prefix of it that ends with `/` or is followed by `/`. So a
    /// `/account` cookie goes to `/account/settings` but not `/accounting`.
    static func browserReplPath(_ requestPath: String, matches cookiePath: String) -> Bool {
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if requestPath.count == cookiePath.count || cookiePath.hasSuffix("/") { return true }
        return requestPath.dropFirst(cookiePath.count).first == "/"
    }

    /// Loopback hosts are potentially trustworthy origins, so a Secure
    /// cookie goes to them over http, as the page's own requests send it.
    static func browserReplIsLoopback(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return bare == "localhost" || bare.hasSuffix(".localhost") || bare == "::1" || bare.hasPrefix("127.")
    }
}

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
        let path = url.path.isEmpty ? "/" : url.path
        guard path.hasPrefix(self.path) else { return false }
        return !isSecure || url.scheme == "https" || Self.browserReplIsLoopback(host)
    }

    /// Loopback hosts are potentially trustworthy origins, so a Secure
    /// cookie goes to them over http, as the page's own requests send it.
    static func browserReplIsLoopback(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return bare == "localhost" || bare.hasSuffix(".localhost") || bare == "::1" || bare.hasPrefix("127.")
    }
}

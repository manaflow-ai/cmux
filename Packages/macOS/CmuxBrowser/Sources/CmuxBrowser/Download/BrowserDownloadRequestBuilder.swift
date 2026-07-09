public import Foundation

/// Builds the `GET` `URLRequest` used by the browser's session-backed download
/// path. Wraps the download target plus the request-shaping inputs (the cookies
/// to forward, the originating page's `Referer`, and the webview's custom
/// `User-Agent`), all captured by value at the call site, so the request is a
/// pure function of those inputs with no live webview or cookie-store state.
///
/// `HTTPCookie` is not `Sendable`, so this builder is intentionally not
/// `Sendable`; it is constructed and consumed synchronously inside the cookie
/// store's completion handler.
public struct BrowserDownloadRequestBuilder {
    /// The URL to download.
    public let url: URL
    /// Cookies to forward as request headers (already filtered for the URL).
    public let cookies: [HTTPCookie]
    /// The originating page's URL string, sent as `Referer` when non-empty.
    public let referer: String?
    /// The webview's custom `User-Agent`, sent when non-empty.
    public let userAgent: String?

    /// Create a builder for `url` with the given cookies, referer, and user agent.
    public init(url: URL, cookies: [HTTPCookie], referer: String?, userAgent: String?) {
        self.url = url
        self.cookies = cookies
        self.referer = referer
        self.userAgent = userAgent
    }

    /// The fully-formed `GET` request with cookie, `Referer`, and `User-Agent`
    /// headers applied.
    public var urlRequest: URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
        for (key, value) in cookieHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let referer = referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let ua = userAgent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        return request
    }
}

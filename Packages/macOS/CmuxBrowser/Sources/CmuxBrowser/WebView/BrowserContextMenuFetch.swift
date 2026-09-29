public import Foundation

/// Builds the native network fetches behind the browser's context-menu
/// "Download" and "Copy Image" actions.
///
/// These fetches run outside WebKit, so the profile's cookies are attached by
/// hand. Each request carries only the cookies WebKit itself would send to the
/// request URL, and a redirect re-scopes them to the redirect target, so an
/// image or file hosted by one site never receives another site's cookies.
public enum BrowserContextMenuFetch {
    /// A GET request for `url` carrying the profile cookies that match it.
    public static func request(
        url: URL,
        profileCookies: [HTTPCookie],
        referer: String?,
        userAgent: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCookies(profileCookies, to: &request)
        if let referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    /// The redirect request with its cookies re-scoped to the redirect URL.
    ///
    /// URLSession copies the original request's headers onto a redirect,
    /// including a hand-set `Cookie` header, so cookies scoped to the first
    /// host would otherwise follow a redirect to any other host.
    public static func redirectedRequest(
        _ redirect: URLRequest,
        profileCookies: [HTTPCookie]
    ) -> URLRequest {
        var request = redirect
        applyCookies(profileCookies, to: &request)
        return request
    }

    private static func applyCookies(_ profileCookies: [HTTPCookie], to request: inout URLRequest) {
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        guard let url = request.url else { return }
        let scoped = CmuxWebView.cookiesForDownloadRequest(profileCookies, url: url)
        for (key, value) in HTTPCookie.requestHeaderFields(with: scoped) {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
}

/// Task delegate that keeps a context-menu fetch's cookies scoped to the
/// current URL across redirects.
final class BrowserContextMenuFetchRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Immutable after init; HTTPCookie is an immutable value holder.
    private let profileCookies: [HTTPCookie]

    init(profileCookies: [HTTPCookie]) {
        self.profileCookies = profileCookies
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(
            BrowserContextMenuFetch.redirectedRequest(request, profileCookies: profileCookies)
        )
    }
}

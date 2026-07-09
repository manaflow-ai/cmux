public import Foundation
public import WebKit

extension WKWebView {
    /// Loads `request` in the receiver, using `loadFileURL(_:allowingReadAccessTo:)`
    /// for local file URLs and a cache-policy-normalized load for everything else.
    ///
    /// Returns `nil` without loading when the request has no URL, or when a local
    /// file URL has no resolvable read-access directory.
    @discardableResult
    public func browserLoadRequest(_ request: URLRequest) -> WKNavigation? {
        guard let url = request.url else { return nil }
        if url.isFileURL {
            guard let readAccessURL = url.browserReadAccessURL() else { return nil }
            return loadFileURL(url, allowingReadAccessTo: readAccessURL)
        }
        return load(browserPreparedNavigationRequest(request))
    }

    /// Normalizes a request for an ordinary load while preserving method/body/headers.
    private func browserPreparedNavigationRequest(_ request: URLRequest) -> URLRequest {
        var preparedRequest = request
        // Match browser behavior for ordinary loads while preserving method/body/headers.
        preparedRequest.cachePolicy = .useProtocolCachePolicy
        return preparedRequest
    }
}

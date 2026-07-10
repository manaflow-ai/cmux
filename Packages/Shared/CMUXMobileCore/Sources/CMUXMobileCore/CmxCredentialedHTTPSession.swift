import Foundation

/// A cookie-free ephemeral URL session for requests that carry account secrets.
///
/// Redirects are rejected before Foundation can reconstruct and forward a
/// request. This is required for custom credential headers because Foundation's
/// normal cross-origin redirect handling strips `Authorization` but can preserve
/// unrelated headers such as a refresh token.
public final class CmxCredentialedHTTPSession: @unchecked Sendable {
    private let redirectDelegate: CmxCredentialedHTTPRedirectDelegate
    private let session: URLSession

    public init(configuration: sending URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectDelegate = CmxCredentialedHTTPRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    deinit {
        session.invalidateAndCancel()
    }
}

final class CmxCredentialedHTTPRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

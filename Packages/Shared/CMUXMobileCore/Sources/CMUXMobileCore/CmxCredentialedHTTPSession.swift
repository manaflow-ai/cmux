import Foundation

public enum CmxCredentialedHTTPSessionError: Error, Equatable, Sendable {
    case responseTooLarge
}

/// A cookie-free ephemeral URL session for requests that carry account secrets.
///
/// Redirects are rejected before Foundation can reconstruct and forward a
/// request. This is required for custom credential headers because Foundation's
/// normal cross-origin redirect handling strips `Authorization` but can preserve
/// unrelated headers such as a refresh token.
public final class CmxCredentialedHTTPSession: @unchecked Sendable {
    public static let defaultMaximumResponseByteCount = 4 * 1_024 * 1_024

    private let redirectDelegate: CmxCredentialedHTTPRedirectDelegate
    private let session: URLSession
    private let maximumResponseByteCount: Int

    public init(
        configuration: sending URLSessionConfiguration = .ephemeral,
        maximumResponseByteCount: Int = defaultMaximumResponseByteCount
    ) {
        precondition(maximumResponseByteCount > 0)
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectDelegate = CmxCredentialedHTTPRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.maximumResponseByteCount = maximumResponseByteCount
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > maximumResponseByteCount {
            bytes.task.cancel()
            throw CmxCredentialedHTTPSessionError.responseTooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(
                min(Int(response.expectedContentLength), maximumResponseByteCount)
            )
        }
        for try await byte in bytes {
            guard data.count < maximumResponseByteCount else {
                bytes.task.cancel()
                throw CmxCredentialedHTTPSessionError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
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

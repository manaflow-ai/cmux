import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectDelegate = CmxCredentialedHTTPRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        // A limit below one byte accepts only an empty body; any byte throws
        // `responseTooLarge`, so no limit value can trap.
        self.maximumResponseByteCount = maximumResponseByteCount
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        // FoundationNetworking has no streaming `bytes(for:)`; the cap applies to the buffered body.
        let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        guard response.expectedContentLength <= maximumResponseByteCount,
              data.count <= max(maximumResponseByteCount, 0) else {
            throw CmxCredentialedHTTPSessionError.responseTooLarge
        }
        return (data, response)
        #else
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > maximumResponseByteCount {
            bytes.task.cancel()
            throw CmxCredentialedHTTPSessionError.responseTooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(
                min(Int(clamping: response.expectedContentLength), maximumResponseByteCount)
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
        #endif
    }

    deinit {
        session.invalidateAndCancel()
    }
}

final class CmxCredentialedHTTPRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    #if canImport(FoundationNetworking)
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
    #else
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
    #endif
}

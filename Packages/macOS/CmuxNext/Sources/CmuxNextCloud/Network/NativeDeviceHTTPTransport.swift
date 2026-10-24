public import Foundation

public protocol NativeDeviceTransport: Sendable {
    /// A fixed, trusted configuration origin, never supplied by a peer or an enrollment reply.
    var origin: URL { get }
    func send(method: String, path: String, body: Data?, bearer: String?, tenant: String?) async throws -> (status: Int, body: Data)
}

/// Native credentials stay in the app. Signed reads have neither bearer nor tenant headers.
public struct NativeDeviceHTTPTransport: NativeDeviceTransport {
    public let origin: URL
    private let session: URLSession
    public init(origin: URL) throws {
        self.origin = try NativeDeviceScope.canonicalOrigin(origin)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: NativeRedirectRefusal(), delegateQueue: nil)
    }
    public func send(method: String, path: String, body: Data?, bearer: String?, tenant: String?) async throws -> (status: Int, body: Data) {
        guard path.hasPrefix("/v1/"), !path.contains(".."), !path.contains("?"), !path.contains("#") else { throw NativeDeviceEnrollmentError.invalidScope }
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        if let tenant { request.setValue(tenant, forHTTPHeaderField: "x-cmux-team-id") }
        let (bytes, response) = try await session.bytes(for: request)
        var result = Data()
        for try await byte in bytes {
            guard result.count < 1_048_576 else { throw NativeDeviceEnrollmentError.invalidIdentity }
            result.append(byte)
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, result)
    }
}

private final class NativeRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

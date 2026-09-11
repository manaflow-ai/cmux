public import Foundation

/// Executes v2 HTTP recovery requests with an injected URLSession.
public actor V2URLSessionHTTPTransport {
    private let session: URLSession

    /// Creates an adapter without global URLSession state.
    /// - Parameter session: The app composition root's dedicated networking session.
    public init(session: URLSession) { self.session = session }

    /// Sends one request with its caller-provided timeout and proof.
    /// - Parameter request: A complete v2 POST request.
    /// - Returns: The HTTP status, bounded bytes, and Retry-After delay.
    /// - Throws: A transport or response-size error.
    public func send(_ request: URLRequest) async throws -> V2HTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw V2ControlFailure.invalidWireData }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw V2ControlFailure.capacityExceeded }
            data.append(byte)
        }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        return V2HTTPResponse(status: response.statusCode, body: data, retryAfter: retryAfter)
    }
}

#if os(iOS)
import Foundation

/// URLSession-backed implementation of ``MobileFeedbackHTTPTransport``.
public struct URLSessionMobileFeedbackTransport: MobileFeedbackHTTPTransport {
    private let session: URLSession

    /// Creates a transport around a URLSession.
    ///
    /// - Parameter session: URLSession used for network requests.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Performs a URL request through the wrapped URLSession.
    ///
    /// - Parameter request: Fully prepared feedback API request.
    /// - Returns: Response data and URL response.
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
#endif

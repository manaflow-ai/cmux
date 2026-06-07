#if os(iOS)
import Foundation

/// Minimal HTTP transport seam for feedback submissions.
public protocol MobileFeedbackHTTPTransport: Sendable {
    /// Performs a URL request and returns the response body and metadata.
    ///
    /// - Parameter request: Fully prepared feedback API request.
    /// - Returns: Response data and URL response.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
#endif

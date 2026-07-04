public import Foundation

/// Performs one HTTP request for an issue source adapter.
public protocol IssueInboxHTTPTransport: Sendable {
    /// Sends a URL request and returns response data plus the HTTP response.
    ///
    /// - Parameter request: Request to send.
    /// - Returns: Response data and HTTP metadata.
    /// - Throws: Transport errors from the underlying client.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

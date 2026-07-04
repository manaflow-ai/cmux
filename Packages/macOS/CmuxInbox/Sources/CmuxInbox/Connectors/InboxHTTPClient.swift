public import Foundation

/// HTTP transport seam for API-backed connectors.
public protocol InboxHTTPClient: Sendable {
    /// Performs a URL request and returns a sendable response value.
    /// - Parameter request: Request to perform.
    func data(for request: URLRequest) async throws -> InboxHTTPResponse
}

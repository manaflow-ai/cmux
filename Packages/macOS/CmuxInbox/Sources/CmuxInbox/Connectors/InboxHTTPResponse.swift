public import Foundation

/// Minimal sendable HTTP response used by connector tests and URLSession adapters.
public struct InboxHTTPResponse: Sendable, Equatable {
    /// HTTP status code.
    public let statusCode: Int
    /// Response headers with lower-level casing preserved.
    public let headers: [String: String]
    /// Response body bytes.
    public let data: Data

    /// Creates a response value.
    public init(statusCode: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

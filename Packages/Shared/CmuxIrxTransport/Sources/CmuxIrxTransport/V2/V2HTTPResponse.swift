public import Foundation

/// A bounded HTTP response at the optional v2 recovery transport boundary.
public struct V2HTTPResponse: Sendable {
    /// HTTP result code returned by the Worker.
    public let status: Int
    /// Generated v2 response JSON.
    public let body: Data
    /// Server-requested retry delay, when supplied.
    public let retryAfter: TimeInterval?

    /// Creates a transport response without interpreting its wire payload.
    /// - Parameters:
    ///   - status: The HTTP status code.
    ///   - body: Raw JSON bytes.
    ///   - retryAfter: Optional delay in seconds from Retry-After.
    public init(status: Int, body: Data, retryAfter: TimeInterval?) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

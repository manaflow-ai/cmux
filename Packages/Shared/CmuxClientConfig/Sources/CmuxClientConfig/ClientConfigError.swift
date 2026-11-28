public import CMUXMobileCore

/// Errors produced by the HTTP client-config loader before response decoding.
public enum ClientConfigError: CmxRetryAfterProviding, Equatable, Sendable {
    /// The configured API base URL could not form a `/api/client-config` URL.
    case invalidBaseURL
    /// The transport returned a non-HTTP response.
    case invalidResponse
    /// The web route returned a non-2xx status code.
    case httpStatus(Int)
    /// The server owns the earliest time another configuration fetch may run.
    case rateLimited(retryAfterSeconds: Int)

    public var retryAfterSeconds: Int? {
        guard case .rateLimited(let seconds) = self else { return nil }
        return seconds
    }
}

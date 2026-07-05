/// Errors produced by the HTTP client-config loader before response decoding.
public enum ClientConfigError: Error, Sendable, Equatable {
    /// The configured API base URL could not form a `/api/client-config` URL.
    case invalidBaseURL
    /// The transport returned a non-HTTP response.
    case invalidResponse
    /// The web route returned a non-2xx status code.
    case httpStatus(Int)
}

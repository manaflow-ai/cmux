/// Failure modes for the email feedback path (``MobileFeedbackEmailSubmitting``).
public enum MobileFeedbackEmailError: Error, Equatable, Sendable {
    /// The web API base URL could not be formed into a valid endpoint.
    case invalidEndpoint
    /// The response was not an HTTP response.
    case invalidResponse
    /// The server rejected the submission with a non-2xx status.
    case rejected(statusCode: Int)
    /// The request failed at the transport layer.
    case transport
}

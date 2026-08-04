import Foundation

/// Errors returned by the native cmux account-deletion request.
public enum AccountDeletionRequestError: Error, Equatable {
    /// The configured cmux API base URL could not build an account-deletion URL.
    case invalidAPIBaseURL
    /// The backend rejected the supplied Stack access or refresh token.
    case unauthorized
    /// cmux data was deleted, but Stack account deletion did not finish.
    case stackDeleteIncomplete
    /// The DELETE request timed out after reaching the transport layer.
    case timedOut
    /// The request may have reached the backend, but no definitive result returned.
    case completionUnknown
    /// The request failed locally before it could plausibly reach the backend.
    case localTransportFailure
    /// The backend returned a definitive non-success status.
    case rejected(statusCode: Int)
    /// URL loading returned a non-HTTP response.
    case invalidResponse
}

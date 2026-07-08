import Foundation

/// Errors thrown while submitting an authenticated mobile account deletion request.
public enum MobileAccountDeletionError: Error, Equatable, Sendable {
    /// The auth runtime had no refresh token to send with the deletion request.
    case missingRefreshToken

    /// The configured API base URL could not form the deletion endpoint URL.
    case invalidURL

    /// The server response was not an HTTP response.
    case invalidResponse

    /// The deletion endpoint returned a non-success HTTP status code.
    case rejected(statusCode: Int)
}

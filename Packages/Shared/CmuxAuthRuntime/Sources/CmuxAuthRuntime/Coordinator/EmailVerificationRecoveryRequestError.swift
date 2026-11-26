import Foundation

/// Failures returned by cmux's email-verification recovery endpoint.
enum EmailVerificationRecoveryRequestError: Error, Equatable, Sendable {
    case invalidAPIBaseURL
    case invalidResponse
    case rateLimited
    case unavailable
}

import Foundation

extension AuthCoordinator {
    /// Sends the one-time verification link that enables email-code sign-in
    /// for an existing account whose primary email was never verified.
    public func requestEmailVerification(for email: String) async throws {
        try await requireOnline()
        do {
            try await EmailVerificationRecoveryClient(
                apiBaseURL: apiBaseURL
            ).requestVerification(for: email)
        } catch EmailVerificationRecoveryRequestError.rateLimited {
            throw AuthError.serverError(429, "rate_limited")
        } catch {
            throw AuthError(displaySafe: error) ?? AuthError.serverError(
                503,
                "email_verification_recovery_unavailable"
            )
        }
    }
}

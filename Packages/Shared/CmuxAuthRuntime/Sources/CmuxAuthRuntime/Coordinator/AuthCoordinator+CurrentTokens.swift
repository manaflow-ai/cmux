import Foundation

extension AuthCoordinator {
    /// Resolves a coherent backend credential pair within one cancellable
    /// network deadline, including launch restore. Session changes reject the
    /// capture; transient refresh failures preserve the existing session.
    /// - Returns: The current access and refresh tokens.
    /// - Throws: Cancellation on cancellation or session replacement, timedOut
    ///   at the deadline, networkError on a recoverable failure, or unauthorized
    ///   when available storage has no recoverable session.
    public func currentTokens() async throws -> (accessToken: String, refreshToken: String) {
        try Task.checkCancellation()
        return try await runTokenTouchingPhase(.accessToken, timeout: timeouts.network) {
            await self.awaitBootstrapped()
            try Task.checkCancellation()
            let generation = await self.authSessionGeneration
            let pair = try await self.coherentTokenPairWithoutStateClear()
            try Task.checkCancellation()
            guard await self.authSessionGeneration == generation else { throw CancellationError() }
            return pair
        }
    }
}

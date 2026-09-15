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
        let deadline = clock.authTokenDeadline(after: timeouts.network)
        // Bootstrap owns sign-in, which joins existing token work. Waiting for
        // bootstrap is read-only and must stay outside that ownership registry.
        try await withAuthPhaseTimeout(
            .accessToken, duration: timeouts.network, clock: clock, log: log,
            registry: phaseTimeoutRegistry,
            blocksRetriesWhileTimedOutOperationActive: false,
            deadline: deadline
        ) {
            await self.awaitBootstrapped()
        }
        try Task.checkCancellation()
        guard !deadline.hasExpired() else { throw AuthError.timedOut }
        return try await runTokenTouchingPhase(.accessToken, timeout: deadline.remaining()) {
            return try await self.captureCloudTokens()
        }
    }

    private func captureCloudTokens() async throws -> (accessToken: String, refreshToken: String) {
        try Task.checkCancellation()
        guard activeSignInFlows.isEmpty, !isCapturingSignOutCredentials else { throw AuthError.networkError }
        let generation = sessionGeneration
        let pair = try await coherentTokenPairWithoutStateClear()
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
        guard activeSignInFlows.isEmpty, !isCapturingSignOutCredentials else { throw AuthError.networkError }
        return pair
    }
}

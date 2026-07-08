internal import CMUXAuthCore
import Foundation
import OSLog

private let authLog = Logger(subsystem: "ai.manaflow.cmux", category: "auth")

extension AuthCoordinator {
    // MARK: - Tokens

    /// The current access token.
    ///
    /// Classifies a missing token the same way ``forceRefreshAccessToken()``
    /// does, so the connection layer can tell a recoverable session from a dead
    /// one: when the SDK could not hand back an access token but a refresh token
    /// is still stored, the failure was transient (network/server) and this
    /// throws ``AuthError/networkError`` so the caller retries without signing
    /// out. When neither token survives, the session is genuinely gone, so this
    /// calls ``clearAuthState()`` (flipping ``isAuthenticated`` to `false`, which
    /// routes the root scene to the sign-in page) and throws
    /// ``AuthError/unauthorized``.
    /// - Returns: A current access token.
    /// - Throws: ``AuthError/networkError`` on a transient failure with a
    ///   surviving refresh token (retryable); ``AuthError/unauthorized`` once the
    ///   session is definitively gone (also clears local auth state).
    public func accessToken() async throws -> String {
        do {
            return try await runTokenTouchingPhase(.accessToken, timeout: timeouts.network) {
                try await self.accessTokenWithoutStateClear()
            }
        } catch AuthError.unauthorized {
            if let devToken = await devAuthAccessTokenFallback() {
                return devToken
            }
            clearAuthState(preservePendingCode: true)
            throw AuthError.unauthorized
        }
    }

    /// Returns the currently stored access token without refreshing or mutating auth state.
    public func storedAccessToken() async -> String? {
        await client.storedAccessToken()
    }

    private func accessTokenWithoutStateClear() async throws -> String {
        if let token = await client.accessToken() {
            return token
        }
        #if DEBUG
        if launch.mockDataEnabled {
            return "cmux-ui-test-stack-token"
        }
        #endif
        // A surviving refresh token means the failure was transient
        // (network/server), so stay retryable; a missing one means the SDK
        // definitively cleared the session and the user must sign in again.
        // The caller performs the published-state clear only for the winning,
        // current request; late timed-out token tasks must not mutate auth UI.
        if await client.refreshToken() != nil {
            throw AuthError.networkError
        }
        throw AuthError.unauthorized
    }

    private func devAuthAccessTokenFallback() async -> String? {
        #if DEBUG
        guard launch.includesDevAuth, let credentials = debugCredentials else {
            return nil
        }
        try? await signInWithPassword(
            email: credentials.email,
            password: credentials.password,
            setLoading: false
        )
        return await client.accessToken()
        #else
        return nil
        #endif
    }

    /// The current refresh token, if any. Native API calls authenticate with
    /// `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>`.
    public func refreshToken() async -> String? {
        await client.refreshToken()
    }

    /// Both tokens for the current session, for callers that talk to
    /// cmux-owned backend endpoints (e.g. the cloud VM service) with the
    /// `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>`
    /// header pair.
    ///
    /// Awaits the launch restore first: RPCs firing before the restore
    /// finishes could otherwise observe an empty token store on a
    /// refresh-token-only start and report "Not signed in" even though a valid
    /// session becomes available moments later.
    /// - Returns: The access and refresh tokens.
    /// - Throws: ``AuthError/networkError`` when the access token is missing
    ///   but a refresh token survives, meaning the refresh failed transiently;
    ///   ``AuthError/unauthorized`` when the session is missing either an access
    ///   token with no refresh token to recover from, or the refresh token
    ///   required by backend requests.
    public func currentTokens() async throws -> (accessToken: String, refreshToken: String) {
        await awaitBootstrapped()
        // `accessToken()` refreshes on demand, but a single transient blip
        // (URLSession throw, brief 5xx/429) makes it return nil while the
        // refresh token survives. That is explicitly retryable, so give the
        // mint a few bounded attempts with short backoff before surfacing
        // `.networkError` — otherwise one hiccup dead-ends callers (the Cloud VM
        // panel) with "could not refresh your session" after "Waited 0s".
        // Each retry re-enters `accessToken()`, which re-attempts the refresh.
        for backoff in Self.currentTokensRetryBackoff {
            if let access = await client.accessToken(), !access.isEmpty {
                guard let refresh = await client.refreshToken(), !refresh.isEmpty else {
                    throw AuthError.unauthorized
                }
                return (access, refresh)
            }
            // Access token empty. Without a refresh token the session is
            // genuinely gone (not retryable); stop immediately.
            guard let refresh = await client.refreshToken(), !refresh.isEmpty else {
                throw AuthError.unauthorized
            }
            _ = refresh
            // A `nil` backoff marks the final attempt: fall through and fail.
            guard let delay = backoff else { break }
            try? await clock.sleep(for: delay)
        }
        throw AuthError.networkError
    }

    /// Backoff schedule for `currentTokens()`. The trailing `nil` is the final
    /// attempt with no further wait, so this yields 3 refresh attempts spaced by
    /// ~0.3s then ~0.8s (worst-case ~1.1s added only on a genuinely failing
    /// refresh; the success path returns on the first attempt with no delay).
    static let currentTokensRetryBackoff: [Duration?] = [
        .milliseconds(300),
        .milliseconds(800),
        nil,
    ]

    /// Force-mint a fresh access token, bypassing the cached-token freshness
    /// check. Call this after the host rejected the current token so the retry
    /// presents a genuinely new credential instead of the same rejected one.
    ///
    /// - Returns: A freshly minted access token.
    /// - Throws: ``AuthError/networkError`` when the refresh failed transiently
    ///   but the session is intact (a refresh token is still stored), so the
    ///   caller should retry rather than sign out; ``AuthError/unauthorized``
    ///   only when the session is genuinely gone (the refresh token was
    ///   definitively rejected and cleared). The definitive case also calls
    ///   ``clearAuthState()`` so ``isAuthenticated`` flips to `false` and the
    ///   root scene routes to the sign-in page instead of showing a stale shell.
    public func forceRefreshAccessToken() async throws -> String {
        do {
            return try await runTokenTouchingPhase(.forceRefreshAccessToken, timeout: timeouts.network) {
                try await self.forceRefreshAccessTokenWithoutStateClear()
            }
        } catch AuthError.unauthorized {
            clearAuthState(preservePendingCode: true)
            throw AuthError.unauthorized
        }
    }

    private func forceRefreshAccessTokenWithoutStateClear() async throws -> String {
        if let token = await client.forceRefreshAccessToken() {
            return token
        }
        // A surviving refresh token means the failure was transient
        // (network/server), so stay retryable; a missing one means the SDK
        // definitively cleared the session.
        if await client.refreshToken() != nil {
            throw AuthError.networkError
        }
        throw AuthError.unauthorized
    }
}

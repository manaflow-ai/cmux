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
        if let token = await client.accessToken() {
            return token
        }
        #if DEBUG
        if launch.mockDataEnabled {
            return "cmux-ui-test-stack-token"
        }
        #endif
        if launch.includesDevAuth, let credentials = debugCredentials {
            try? await signInWithPassword(
                email: credentials.email,
                password: credentials.password,
                setLoading: false
            )
            if let token = await client.accessToken() {
                return token
            }
        }
        // A surviving refresh token means the failure was transient
        // (network/server), so stay retryable; a missing one means the SDK
        // definitively cleared the session and the user must sign in again.
        if await client.refreshToken() != nil {
            throw AuthError.networkError
        }
        clearAuthState(preservePendingCode: true)
        throw AuthError.unauthorized
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
    /// - Throws: ``AuthError/unauthorized`` when either token is missing.
    public func currentTokens() async throws -> (accessToken: String, refreshToken: String) {
        await awaitBootstrapped()
        guard let access = await client.accessToken(), !access.isEmpty else {
            throw AuthError.unauthorized
        }
        guard let refresh = await client.refreshToken(), !refresh.isEmpty else {
            throw AuthError.unauthorized
        }
        return (access, refresh)
    }

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
        if let token = await client.forceRefreshAccessToken() {
            return token
        }
        // A surviving refresh token means the failure was transient
        // (network/server), so stay retryable; a missing one means the SDK
        // definitively cleared the session.
        if await client.refreshToken() != nil {
            throw AuthError.networkError
        }
        clearAuthState(preservePendingCode: true)
        throw AuthError.unauthorized
    }
}

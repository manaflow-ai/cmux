public import CMUXAuthCore
import Foundation

/// The auth backend seam the ``AuthCoordinator`` drives.
///
/// Abstracts every Stack Auth operation the coordinator needs so it can be
/// tested with an in-memory fake. The production conformer is
/// ``StackAuthClient``, which wraps `StackClientApp`. Construct it once at the
/// app composition root with injected config and inject it as `any AuthClient`.
public protocol AuthClient: Sendable {
    /// The current Stack access token, or `nil` when there is no live session.
    func accessToken() async -> String?

    /// The current Stack refresh token, or `nil` when there is no live session.
    func refreshToken() async -> String?

    /// Force-mint a fresh access token from the stored refresh token, bypassing
    /// the cached-token freshness check.
    ///
    /// Call this after the server has rejected the current access token: a normal
    /// ``accessToken()`` would hand back the same still-"fresh enough" token and
    /// the rejection would repeat. Returns `nil` when no new token could be
    /// obtained (a transient failure, or the refresh token was definitively
    /// rejected and cleared). The caller distinguishes the two by checking
    /// ``refreshToken()`` afterward: a surviving refresh token means the failure
    /// was transient and the caller should retry rather than sign out.
    /// - Returns: A freshly minted access token, or `nil` when none was obtained.
    func forceRefreshAccessToken() async -> String?

    /// Fetch the signed-in user, returning `nil` when no user is present.
    ///
    /// - Parameter throwOnMissing: When `true`, the client throws on token
    ///   validation failure instead of returning `nil`, so the coordinator can
    ///   distinguish "no session" from "session validation failed".
    /// - Returns: The mapped current user value, if any.
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser?

    /// List the teams the signed-in user belongs to.
    /// - Returns: The user's teams; empty when no user is signed in.
    func listTeams() async throws -> [CMUXAuthTeam]

    /// Send a magic-link email and return the opaque nonce to combine with the
    /// user-entered code.
    /// - Parameters:
    ///   - email: The recipient email address.
    ///   - callbackURL: The auth callback URL the link should target.
    /// - Returns: The nonce to compose with the entered code at verification.
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String

    /// Complete a magic-link sign-in with the composed code (`code` + `nonce`).
    func signInWithMagicLink(code: String) async throws

    /// Sign in with an email/password credential.
    func signInWithCredential(email: String, password: String) async throws

    /// Sign in with an OAuth provider (e.g. `"apple"`, `"google"`), presenting
    /// from the supplied anchor.
    /// - Parameters:
    ///   - provider: The provider identifier.
    ///   - anchor: The presentation-anchor provider for the auth UI.
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws

    /// The access token exactly as stored, with no freshness check and no
    /// network refresh (unlike ``accessToken()``, which may mint a new token
    /// over the network when the stored one looks stale).
    ///
    /// For capturing the credentials a best-effort server-side teardown needs
    /// before ``clearLocalSession()`` destroys them; never blocks on
    /// connectivity.
    func storedAccessToken() async -> String?

    /// Clear the locally persisted session (tokens) without any network call.
    /// The device is signed out once this returns, regardless of connectivity.
    func clearLocalSession() async

    /// Revoke the server-side session the captured token pair authenticates,
    /// without touching local token storage (the local session is typically
    /// already cleared by ``clearLocalSession()`` when this runs).
    ///
    /// Best-effort by contract: callers bound it with a deadline and log
    /// failures rather than letting revocation gate sign-out.
    func revokeSession(accessToken: String?, refreshToken: String?) async throws

    /// Mint a fresh access token from an explicit refresh token, touching no
    /// local token storage (an ephemeral store backs the mint).
    ///
    /// For the sign-out teardown when only a refresh token survived at
    /// capture time (the SDK drops expired access tokens): the cmux API
    /// authenticates with the Bearer + refresh header pair, so the bounded
    /// best-effort teardown needs a usable access token even though the local
    /// session is already cleared. Best-effort: returns `nil` when the mint
    /// fails (offline, dead server).
    func mintAccessToken(refreshToken: String) async -> String?
}

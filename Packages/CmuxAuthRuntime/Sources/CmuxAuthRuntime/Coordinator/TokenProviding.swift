import Foundation

/// Supplies the auth tokens needed to authenticate cmux web API calls.
///
/// Native API calls send `Authorization: Bearer <access>` plus
/// `X-Stack-Refresh-Token: <refresh>`, so consumers need both. ``AuthCoordinator``
/// is the production conformer; inject it as `any TokenProviding` into services
/// that talk to the web API (e.g. ``PushRegistrationService``) so they never
/// reach for an auth singleton.
public protocol TokenProviding: Sendable {
    /// The current access token, throwing when there is no valid session.
    func accessToken() async throws -> String
    /// The current refresh token, or `nil` when there is no valid session.
    func refreshToken() async -> String?
    /// Force-mint a fresh access token, bypassing the cached-token freshness
    /// check.
    ///
    /// Call this after the host has rejected the current token so a retry
    /// presents a genuinely new credential instead of re-sending the rejected
    /// (likely stale) token.
    /// - Throws: ``AuthError/networkError`` when the refresh failed transiently
    ///   but the session is intact (a refresh token is still stored), so the
    ///   caller should retry rather than sign out; ``AuthError/unauthorized``
    ///   only when the session is genuinely gone.
    /// - Returns: A freshly minted access token.
    func forceRefreshAccessToken() async throws -> String

    /// The stable id of the currently signed-in user, or `nil` when signed out.
    ///
    /// Used to namespace per-user client state (e.g. the push muted-workspace
    /// set) so a different account signing in on the same device can never read
    /// or write the previous account's state, independent of task ordering.
    func currentUserID() async -> String?
}

extension AuthCoordinator: TokenProviding {
    /// The signed-in Stack user's stable id, or `nil` when signed out. Returns
    /// the cached ``currentUser`` id; used to namespace per-user push state.
    public func currentUserID() async -> String? { currentUser?.id }
}

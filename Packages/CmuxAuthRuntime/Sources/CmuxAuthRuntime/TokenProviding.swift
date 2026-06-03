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
}

extension AuthCoordinator: TokenProviding {}

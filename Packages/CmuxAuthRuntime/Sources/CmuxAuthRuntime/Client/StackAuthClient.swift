public import CMUXAuthCore
import Foundation
public import StackAuth

/// The production ``AuthClient``, wrapping a Stack Auth `StackClientApp`.
///
/// Constructed once at the app composition root with an injected ``AuthConfig``
/// and `TokenStoreInit`, replacing the deleted `StackAuthApp.shared` singleton.
/// The wrapped `StackClientApp` is an actor, so this conformer is `Sendable` and
/// safe to inject as `any AuthClient`.
public struct StackAuthClient: AuthClient {
    private let stack: StackClientApp

    /// Wrap a Stack client app.
    /// - Parameter stack: The configured Stack client to delegate to.
    public init(stack: StackClientApp) {
        self.stack = stack
    }

    /// Build a Stack client from resolved config and a token-store choice.
    ///
    /// - Parameters:
    ///   - config: The resolved auth configuration (project id + publishable key).
    ///   - tokenStore: Where Stack persists tokens. Pass `.memory` for the
    ///     simulator DEBUG flow and `.keychain` for real devices/release.
    public init(config: AuthConfig, tokenStore: TokenStoreInit) {
        self.init(
            stack: StackClientApp(
                projectId: config.stack.projectId,
                publishableClientKey: config.stack.publishableClientKey,
                tokenStore: tokenStore
            )
        )
    }

    public func accessToken() async -> String? {
        await stack.getAccessToken()
    }

    public func refreshToken() async -> String? {
        await stack.getRefreshToken()
    }

    public func forceRefreshAccessToken() async -> String? {
        await stack.fetchNewAccessToken()
    }

    public func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        guard let user = try await stack.getUser(or: throwOnMissing ? .throw : .returnNull) else {
            return nil
        }
        return await Self.mapped(user)
    }

    public func listTeams() async throws -> [CMUXAuthTeam] {
        guard let user = try await stack.getUser(or: .returnNull) else {
            return []
        }
        let teams = try await user.listTeams()
        var summaries: [CMUXAuthTeam] = []
        summaries.reserveCapacity(teams.count)
        for team in teams {
            summaries.append(CMUXAuthTeam(id: team.id, displayName: await team.displayName))
        }
        return summaries
    }

    public func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String {
        try await stack.sendMagicLinkEmail(email: email, callbackUrl: callbackURL)
    }

    public func signInWithMagicLink(code: String) async throws {
        try await stack.signInWithMagicLink(code: code)
    }

    public func signInWithCredential(email: String, password: String) async throws {
        try await stack.signInWithCredential(email: email, password: password)
    }

    public func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {
        try await stack.signInWithOAuth(provider: provider, presentationContextProvider: anchor)
    }

    public func storedAccessToken() async -> String? {
        await stack.getStoredAccessToken()
    }

    public func clearLocalSession() async {
        await stack.clearStoredTokens()
    }

    public func revokeSession(accessToken: String?, refreshToken: String?) async throws {
        // Nothing to authenticate the DELETE with; skip the round trip.
        guard accessToken != nil || refreshToken != nil else { return }
        try await stack.revokeSession(accessToken: accessToken, refreshToken: refreshToken)
    }

    public func mintAccessToken(refreshToken: String) async -> String? {
        await stack.mintAccessToken(refreshToken: refreshToken)
    }

    private static func mapped(_ user: CurrentUser) async -> CMUXAuthUser {
        let id = await user.id
        let email = await user.primaryEmail
        let name = await user.displayName
        return CMUXAuthUser(id: id, primaryEmail: email, displayName: name)
    }
}

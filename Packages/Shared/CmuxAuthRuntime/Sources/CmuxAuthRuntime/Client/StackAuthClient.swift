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
    private let apiBaseURL: URL?

    /// Wrap a Stack client app.
    /// - Parameter stack: The configured Stack client to delegate to.
    public init(stack: StackClientApp) {
        self.stack = stack
        self.apiBaseURL = nil
    }

    private init(stack: StackClientApp, apiBaseURL: URL?) {
        self.stack = stack
        self.apiBaseURL = apiBaseURL
    }

    /// Build a Stack client from resolved config and a token-store choice.
    ///
    /// - Parameters:
    ///   - config: The resolved auth configuration (project id + publishable key).
    ///   - tokenStore: Where Stack persists tokens. Pass `.memory` for the
    ///     simulator DEBUG flow and `.keychain` for real devices/release.
    ///   - oauthBrowserSessionPrivacy: Whether OAuth may reuse Safari cookies.
    ///   - baseURL: Stack API origin. Defaults to Stack's production API.
    ///   - noAutomaticPrefetch: Disables Stack project prefetch when the host
    ///     owns startup sequencing.
    public init(
        config: AuthConfig,
        tokenStore: TokenStoreInit,
        oauthBrowserSessionPrivacy: OAuthBrowserSessionPrivacy = .shared,
        baseURL: String = "https://api.stack-auth.com",
        noAutomaticPrefetch: Bool = false
    ) {
        self.init(
            stack: StackClientApp(
                projectId: config.stack.projectId,
                publishableClientKey: config.stack.publishableClientKey,
                baseUrl: baseURL,
                tokenStore: tokenStore,
                noAutomaticPrefetch: noAutomaticPrefetch,
                oauthBrowserSessionPrivacy: oauthBrowserSessionPrivacy
            ),
            apiBaseURL: URL(string: config.apiBaseURL)
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

    public func selectedTeamID() async throws -> String? {
        guard let user = try await stack.getUser(or: .returnNull) else { return nil }
        return await user.selectedTeam?.id
    }

    public func setSelectedTeam(id: String?) async throws {
        guard let user = try await stack.getUser(or: .returnNull) else {
            throw AuthClientError.unsupported
        }
        try await user.setSelectedTeam(id: id)
    }

    public func createTeam(displayName: String) async throws -> CMUXAuthTeam {
        if let apiBaseURL {
            return try await createTeamThroughCmuxBackend(displayName: displayName, apiBaseURL: apiBaseURL)
        }
        guard let user = try await stack.getUser(or: .returnNull) else {
            throw AuthClientError.unsupported
        }
        let team = try await user.createTeam(displayName: displayName)
        return CMUXAuthTeam(
            id: team.id,
            displayName: await team.displayName
        )
    }

    private func createTeamThroughCmuxBackend(
        displayName: String,
        apiBaseURL: URL
    ) async throws -> CMUXAuthTeam {
        guard let accessToken = await stack.getAccessToken(),
              let refreshToken = await stack.getRefreshToken() else {
            throw AuthClientError.unsupported
        }
        let endpoint = apiBaseURL.appendingPathComponent("api/subrouter/teams")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.httpBody = try JSONEncoder().encode(CreateTeamRequest(displayName: displayName))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw AuthClientError.unsupported
        }
        let created = try JSONDecoder().decode(CreateTeamResponse.self, from: data)
        return CMUXAuthTeam(id: created.team.id, displayName: created.team.name)
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

    /// The access token exactly as stored: a raw read, no freshness check,
    /// no network refresh. See ``AuthClient/storedAccessToken()``.
    public func storedAccessToken() async -> String? {
        await stack.getStoredAccessToken()
    }

    /// Clear the locally persisted Stack session unconditionally, with no
    /// network call. See ``AuthClient/clearLocalSession()``.
    public func clearLocalSession() async {
        await stack.clearStoredTokens()
    }

    /// Compare-and-clear the locally persisted Stack session, atomic at the
    /// SDK token store. See
    /// ``AuthClient/clearLocalSession(ifRefreshTokenMatches:)``.
    public func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {
        await stack.clearStoredTokens(ifRefreshTokenEquals: refreshToken)
    }

    /// Revoke the server-side session the captured token pair authenticates,
    /// through an ephemeral token store that never writes to the app's real
    /// keychain. See ``AuthClient/revokeSession(accessToken:refreshToken:)``.
    public func revokeSession(accessToken: String?, refreshToken: String?) async throws {
        // Nothing to authenticate the DELETE with; skip the round trip.
        guard accessToken != nil || refreshToken != nil else { return }
        try await stack.revokeSession(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// A likely-valid access token for an explicit captured pair, resolved
    /// without touching local token storage. See
    /// ``AuthClient/freshAccessToken(accessToken:refreshToken:)``.
    public func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? {
        await stack.likelyValidAccessToken(accessToken: accessToken, refreshToken: refreshToken)
    }

    private static func mapped(_ user: CurrentUser) async -> CMUXAuthUser {
        let id = await user.id
        let email = await user.primaryEmail
        let name = await user.displayName
        let profileImageURL = await user.profileImageUrl
        let demonstrationContentEnabled = await user.cmuxDemonstrationContentEnabled
        return CMUXAuthUser(
            id: id,
            primaryEmail: email,
            displayName: name,
            profileImageURL: profileImageURL,
            demonstrationContentEnabled: demonstrationContentEnabled
        )
    }
}

extension CurrentUser {
    /// Resolves the server-written demonstration-content flag inside the
    /// user actor, so the non-`Sendable` metadata dictionary never crosses an
    /// isolation boundary. See
    /// ``CMUXAuthUser/demonstrationContentEnabled(fromClientReadOnlyMetadata:)``.
    var cmuxDemonstrationContentEnabled: Bool {
        CMUXAuthUser.demonstrationContentEnabled(
            fromClientReadOnlyMetadata: clientReadOnlyMetadata
        )
    }
}

private struct CreateTeamRequest: Encodable {
    let displayName: String
}

private struct CreateTeamResponse: Decodable {
    let team: TeamSummary

    struct TeamSummary: Decodable {
        let id: String
        let name: String
    }
}

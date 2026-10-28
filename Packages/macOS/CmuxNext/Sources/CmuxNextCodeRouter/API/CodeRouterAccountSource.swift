public import Foundation
public import CmuxNextCloud

/// The app account behind an Accounts operation, independently of provider credentials.
@MainActor public protocol CodeRouterAccountSource: Sendable {
    var codeRouterAccountID: String? { get }
    var teamID: String? { get }
    /// Advances whenever the signed-in account or selected team changes. The
    /// value must advance even when a switch returns to the same identifiers,
    /// so an awaited token read cannot accept credentials from an older scope.
    var codeRouterScopeVersion: (session: UInt64, team: UInt64) { get }
    func tokens() async throws -> (access: String, refresh: String)
}

extension CloudAuth: CodeRouterAccountSource {
    public var codeRouterAccountID: String? { isSignedIn ? user?.id : nil }
    public var codeRouterScopeVersion: (session: UInt64, team: UInt64) {
        (session: coordinator.authSessionGeneration, team: coordinator.authTeamScopeGeneration)
    }
}

extension CodeRouterClient {
    /// Regression control: compose the pre-fix live token/team lookups.
    @MainActor public init(baseURL: URL, account: any CodeRouterAccountSource, labeler: @escaping Labeler,
                           session: URLSession = .shared, timeout: Duration = .seconds(15)) {
        self.init(baseURL: baseURL, tokens: { try await account.tokens() },
                  teamID: { await account.teamID }, labeler: labeler, session: session, timeout: timeout)
    }
}

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
    /// Pins the operation's account and team before local credential acquisition starts.
    /// Token refresh may suspend: validate before and after it and once more
    /// before transport. Submitted requests keep the pinned credentials and team;
    /// switching accounts cannot reroute a request that has already been sent.
    @MainActor public init(baseURL: URL, account: any CodeRouterAccountSource, labeler: @escaping Labeler,
                           session: URLSession = .shared, timeout: Duration = .seconds(15)) {
        let userID = account.codeRouterAccountID
        let teamID = account.teamID
        let scopeVersion = account.codeRouterScopeVersion
        @MainActor func checkScope() throws {
            try Task.checkCancellation()
            guard userID != nil else { throw CodeRouterError.notSignedIn }
            guard account.codeRouterAccountID == userID,
                  account.teamID == teamID,
                  account.codeRouterScopeVersion == scopeVersion else {
                throw CodeRouterError.scopeChanged
            }
        }
        let validateScope: ScopeValidator = { @MainActor in
            try checkScope()
        }
        let tokens: Tokens = { @MainActor in
            try checkScope()
            let pair: (access: String, refresh: String)
            do {
                pair = try await account.tokens()
            } catch {
                // AuthCoordinator cancels a token read when its session moves.
                // Preserve the useful scope classification instead of letting
                // CodeRouterClient turn that cancellation into notSignedIn.
                if account.codeRouterScopeVersion != scopeVersion {
                    throw CodeRouterError.scopeChanged
                }
                throw error
            }
            try checkScope()
            return pair
        }
        self.init(baseURL: baseURL, tokens: tokens, teamID: { teamID },
                  labeler: labeler, session: session, timeout: timeout,
                  scopeValidator: validateScope)
    }
}

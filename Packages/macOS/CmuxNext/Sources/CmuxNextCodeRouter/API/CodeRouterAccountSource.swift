public import Foundation
public import CmuxNextCloud

/// The app account behind an Accounts operation, independently of provider credentials.
@MainActor public protocol CodeRouterAccountSource: Sendable {
    var codeRouterAccountID: String? { get }
    var teamID: String? { get }
    func tokens() async throws -> (access: String, refresh: String)
}

extension CloudAuth: CodeRouterAccountSource {
    public var codeRouterAccountID: String? { isSignedIn ? user?.id : nil }
}

extension CodeRouterClient {
    /// Pins the operation's account and team before local credential acquisition starts.
    /// Token refresh may suspend: validate the scope both before and after it. The
    /// later request header reads the pinned team, never another account's selection.
    @MainActor public init(baseURL: URL, account: any CodeRouterAccountSource, labeler: @escaping Labeler,
                           session: URLSession = .shared, timeout: Duration = .seconds(15)) {
        let userID = account.codeRouterAccountID
        let teamID = account.teamID
        let tokens: Tokens = { @MainActor in
            func checkScope() throws {
                try Task.checkCancellation()
                guard userID != nil, account.codeRouterAccountID == userID, account.teamID == teamID else {
                    throw CodeRouterError.scopeChanged
                }
            }
            try checkScope()
            let pair = try await account.tokens()
            try checkScope()
            return pair
        }
        self.init(baseURL: baseURL, tokens: tokens, teamID: { teamID },
                  labeler: labeler, session: session, timeout: timeout)
    }
}

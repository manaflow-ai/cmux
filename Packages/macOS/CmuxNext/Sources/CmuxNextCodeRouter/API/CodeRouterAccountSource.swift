public import Foundation

/// The app account behind an Accounts operation, independently of provider credentials.
@MainActor public protocol CodeRouterAccountSource: Sendable {
    var codeRouterAccountID: String? { get }
    var teamID: String? { get }
    func tokens() async throws -> (access: String, refresh: String)
}

extension CodeRouterClient {
    /// Composes the account-backed client before local credential acquisition starts.
    @MainActor public init(baseURL: URL, account: any CodeRouterAccountSource, labeler: @escaping Labeler,
                           session: URLSession = .shared, timeout: Duration = .seconds(15)) {
        self.init(baseURL: baseURL, tokens: { try await account.tokens() },
                  teamID: { await account.teamID }, labeler: labeler, session: session, timeout: timeout)
    }
}

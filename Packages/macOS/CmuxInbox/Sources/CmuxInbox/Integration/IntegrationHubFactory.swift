public import Foundation

/// Builds the production-shaped cmux inbox hub.
public struct IntegrationHubFactory: Sendable {
    private let tokenStore: any InboxTokenStoring
    private let httpClient: any InboxHTTPClient
    private let iMessageHelperPaths: [URL]

    /// Creates a hub factory.
    /// - Parameters:
    ///   - tokenStore: Secure token store.
    ///   - httpClient: HTTP transport.
    ///   - iMessageHelperPaths: Candidate helper binary paths.
    public init(
        tokenStore: any InboxTokenStoring = InboxKeychainTokenVault(),
        httpClient: any InboxHTTPClient = URLSessionInboxHTTPClient(),
        iMessageHelperPaths: [URL] = LocalIMessageHelperClient.defaultHelperPaths()
    ) {
        self.tokenStore = tokenStore
        self.httpClient = httpClient
        self.iMessageHelperPaths = iMessageHelperPaths
    }

    /// Creates a live hub and local store.
    /// - Parameter databaseURL: Optional database URL override.
    public func makeHub(databaseURL: URL? = nil) throws -> IntegrationHub {
        let store = try InboxSQLiteStore(databaseURL: databaseURL)
        let connectors: [any InboxConnector] = [
            GenericInboxConnector(),
            IMessageHelperConnector(helper: LocalIMessageHelperClient(candidatePaths: iMessageHelperPaths)),
            SlackConnector(tokenStore: tokenStore, httpClient: httpClient),
            GmailConnector(tokenStore: tokenStore, httpClient: httpClient),
            DiscordConnector(tokenStore: tokenStore, httpClient: httpClient),
        ]
        return IntegrationHub(store: store, connectors: connectors, tokenStore: tokenStore)
    }
}

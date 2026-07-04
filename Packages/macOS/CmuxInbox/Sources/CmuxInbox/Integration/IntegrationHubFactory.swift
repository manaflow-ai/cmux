public import Foundation

/// Builds the production-shaped cmux inbox hub.
public struct IntegrationHubFactory: Sendable {
    private let tokenStore: any InboxTokenStoring
    private let httpClient: any InboxHTTPClient
    private let iMessageHelperPaths: [URL]

    /// Creates a hub factory.
    /// - Parameters:
    ///   - tokenStore: Secure token store. The default layers Keychain over the
    ///     secure file vault so linking still works in tagged Debug builds,
    ///     where Keychain writes fail with `errSecMissingEntitlement`.
    ///   - httpClient: HTTP transport.
    ///   - iMessageHelperPaths: Candidate helper binary paths.
    public init(
        tokenStore: any InboxTokenStoring = InboxLayeredTokenStore(
            primary: InboxKeychainTokenVault(),
            fallback: InboxFileTokenVault()
        ),
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
            NotificationCenterConnector(
                helper: LocalIMessageHelperClient(
                    candidatePaths: LocalIMessageHelperClient.defaultHelperPaths(binaryName: "cmux-notif")
                )
            ),
            SlackConnector(tokenStore: tokenStore, httpClient: httpClient, apiBase: Self.slackAPIBase()),
            GmailConnector(tokenStore: tokenStore, httpClient: httpClient),
            DiscordConnector(tokenStore: tokenStore, httpClient: httpClient),
        ]
        return IntegrationHub(store: store, connectors: connectors, tokenStore: tokenStore)
    }

    /// Debug builds may point Slack at a local protocol-compatible server for
    /// end-to-end pipeline verification. Release builds ignore the override:
    /// honoring an env var there would let a hostile environment redirect
    /// API calls carrying the user's token.
    private static func slackAPIBase() -> URL {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CMUX_SLACK_API_BASE"],
           let url = URL(string: raw), url.scheme == "http" || url.scheme == "https",
           let host = url.host, host == "127.0.0.1" || host == "localhost" {
            return url
        }
        #endif
        return SlackConnector.productionAPIBase
    }
}

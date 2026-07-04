import Foundation
import Testing
import CmuxInbox

@Suite struct IntegrationHubTests {
    private let fixtures = InboxFixtures()

    @Test func sendReplyRequiresConnectorCapabilityAndLeavesExternalSendExplicit() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let connector = StubConnector(source: .generic, capabilities: [.backfill])
        let hub = IntegrationHub(store: store, connectors: [connector])
        let thread = fixtures.thread(source: .generic)
        let item = fixtures.item(source: .generic, threadID: thread.threadID)
        try await hub.push(account: fixtures.account(source: .generic), thread: thread, item: item)

        let draft = try await hub.draftReply(threadID: thread.threadID, instruction: "Use a short reply")
        #expect(draft.status == .editing)

        do {
            _ = try await hub.sendApprovedReply(draftID: draft.draftID)
            Issue.record("Expected unsupported send without sendReply capability")
        } catch InboxError.unsupported(let message) {
            #expect(message.contains("generic"))
        }
        #expect(await connector.sentCount() == 0)
    }

    @Test func approvedSendPersistsSentDraftAfterConnectorSuccess() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let connector = StubConnector(source: .generic, capabilities: [.backfill, .sendReply])
        let hub = IntegrationHub(store: store, connectors: [connector])
        let thread = fixtures.thread(source: .generic)
        let item = fixtures.item(source: .generic, threadID: thread.threadID)
        try await hub.push(account: fixtures.account(source: .generic), thread: thread, item: item)

        let draft = try await hub.draftReply(threadID: thread.threadID, instruction: "Ship it")
        let sent = try await hub.sendApprovedReply(draftID: draft.draftID)

        #expect(sent.status == .sent)
        #expect(sent.approvedAt != nil)
        #expect(sent.sentAt != nil)
        #expect(await connector.sentCount() == 1)
    }

    @Test func connectStoresTokensOnlyInTokenStoreAndReportsRedactedCredentialState() async throws {
        let url = fixtures.temporaryDatabaseURL()
        let store = try InboxSQLiteStore(databaseURL: url)
        let tokens = MemoryTokenStore()
        let http = StubHTTPClient(responses: [])
        let slack = SlackConnector(tokenStore: tokens, httpClient: http)
        let hub = IntegrationHub(store: store, connectors: [slack], tokenStore: tokens)

        let status = try await hub.connect(
            source: .slack,
            accountID: "default",
            displayName: "Workspace",
            token: "super-secret-token"
        )
        #expect(status.credentialState == .present)
        #expect(status.message == nil)
        #expect(try await tokens.token(source: .slack, accountID: "default") == Data("super-secret-token".utf8))

        let databaseBytes = try Data(contentsOf: url)
        #expect(String(data: databaseBytes, encoding: .utf8)?.contains("super-secret-token") != true)
    }

    @Test func connectResolvesDefaultSentinelToConnectorCanonicalAccountID() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let tokens = MemoryTokenStore()
        let http = StubHTTPClient(responses: [])
        let gmail = GmailConnector(tokenStore: tokens, httpClient: http)
        let hub = IntegrationHub(store: store, connectors: [gmail], tokenStore: tokens)

        // Settings and the CLI default to accountID "default"; GmailConnector
        // reads tokens under its canonical "me". Connect must store the token
        // where the connector will read it, and disconnect must delete it there.
        let status = try await hub.connect(source: .gmail, accountID: "default", token: "gmail-oauth-token")
        #expect(status.accountID == "me")
        #expect(status.status == .connected)
        #expect(try await tokens.token(source: .gmail, accountID: "me") == Data("gmail-oauth-token".utf8))
        #expect(try await tokens.token(source: .gmail, accountID: "default") == nil)
        #expect(try await hub.accounts().map(\.accountID) == ["me"])

        _ = try await hub.disconnect(source: .gmail, accountID: "default")
        #expect(try await tokens.token(source: .gmail, accountID: "me") == nil)

        // Explicit non-sentinel account ids are respected untouched.
        let explicit = try await hub.connect(source: .gmail, accountID: "work@example.com", token: "work-token")
        #expect(explicit.accountID == "work@example.com")
        #expect(try await tokens.token(source: .gmail, accountID: "work@example.com") == Data("work-token".utf8))
    }

    @Test func approvedSendDeliversLatestPersistedDraftBody() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let connector = StubConnector(source: .generic, capabilities: [.backfill, .sendReply])
        let hub = IntegrationHub(store: store, connectors: [connector])
        let thread = fixtures.thread(source: .generic)
        let item = fixtures.item(source: .generic, threadID: thread.threadID)
        try await hub.push(account: fixtures.account(source: .generic), thread: thread, item: item)

        // The app keeps editor keystrokes local and flushes once before the
        // approved send; the hub contract is update-then-send delivering the
        // flushed body, never the original generated draft.
        let draft = try await hub.draftReply(threadID: thread.threadID, instruction: "Generated draft")
        _ = try await hub.updateDraftBody(draftID: draft.draftID, body: "Edited final body")
        let sent = try await hub.sendApprovedReply(draftID: draft.draftID)

        #expect(sent.status == .sent)
        #expect(sent.body == "Edited final body")
        #expect(await connector.sentBodyList() == ["Edited final body"])
    }

    @Test func syncStatusUpsertPreservesNotificationsOptOut() async throws {
        let store = try InboxSQLiteStore(databaseURL: fixtures.temporaryDatabaseURL())
        let tokens = MemoryTokenStore(tokens: ["slack:default": "xoxb-test"])
        let http = StubHTTPClient(responses: [])
        let slack = SlackConnector(tokenStore: tokens, httpClient: http)
        let hub = IntegrationHub(store: store, connectors: [slack], tokenStore: tokens)

        _ = try await hub.connect(source: .slack, accountID: "default", displayName: "Workspace")
        try await hub.setNotificationsEnabled(source: .slack, accountID: "default", enabled: false)

        // Slack with a token but no channel IDs reports a degraded account
        // built with the model default notificationsEnabled=true; syncing must
        // not clobber the persisted opt-out.
        _ = await hub.sync(source: .slack)

        let account = try #require(try await hub.accounts().first { $0.source == .slack })
        #expect(account.status == .degraded)
        #expect(account.notificationsEnabled == false)
    }
}

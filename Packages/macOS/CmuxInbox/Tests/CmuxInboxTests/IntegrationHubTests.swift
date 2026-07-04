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
}

import Foundation
import Testing
import CmuxInbox

@Suite struct ConnectorFixtureTests {
    @Test func imessageHelperStatusAndRecentJSONParseUserSafeStates() throws {
        let denied = try IMessageHelperJSONAdapter.status(from: Data(#"{"ok":false,"message":"Messages permission denied","last_sync_at":1700000000,"permission_denied":true}"#.utf8))
        #expect(denied.ok == false)
        #expect(denied.permissionDenied == true)
        #expect(denied.message == "Messages permission denied")

        let result = try IMessageHelperJSONAdapter.syncResult(from: Data(#"{"account_id":"local","cursor":"c2","threads":[{"thread_id":"chat-1","display_name":"Austin","last_activity_at":1700000001}],"messages":[{"thread_id":"chat-1","message_id":"m1","sender":"Austin","timestamp":1700000001,"preview":"hello","body":"hello from Messages","unread":true,"actionable":true}]}"#.utf8))
        #expect(result.nextCursor == "c2")
        #expect(result.threads.count == 1)
        #expect(result.items.first?.source == .imessage)
        #expect(result.items.first?.isActionable == true)
    }

    @Test func slackBackfillEventsRateLimitAndTokenExpiryAreModeled() async throws {
        let tokens = MemoryTokenStore(tokens: ["slack:default": "xoxb-test"])
        let http = StubHTTPClient(responses: [
            InboxHTTPResponse(statusCode: 200, data: Data(#"{"ok":true,"messages":[{"ts":"1700000000.000100","text":"hello slack","user":"U123","unread":true}]}"#.utf8)),
        ])
        let connector = SlackConnector(channelIDs: ["C123"], tokenStore: tokens, httpClient: http)

        let result = try await connector.sync(cursor: nil)
        #expect(result.status.status == .connected)
        #expect(result.items.first?.source == .slack)
        #expect(result.items.first?.bodyPreview == "hello slack")
        #expect(await http.authorizationHeaders() == ["Bearer xoxb-test"])

        let mention = try await connector.itemFromEventPayload(Data(#"{"event":{"type":"app_mention","channel":"C123","ts":"1700000001.000200","thread_ts":"1700000000.000100","user":"U123","text":"<@bot> help"}}"#.utf8))
        #expect(mention?.isActionable == true)
        #expect(mention?.metadata["thread_ts"] == "1700000000.000100")

        let limited = SlackConnector(channelIDs: ["C123"], tokenStore: tokens, httpClient: StubHTTPClient(responses: [
            InboxHTTPResponse(statusCode: 429),
        ]))
        #expect(try await limited.sync(cursor: nil).status.status == .rateLimited)

        let expired = SlackConnector(channelIDs: ["C123"], tokenStore: tokens, httpClient: StubHTTPClient(responses: [
            InboxHTTPResponse(statusCode: 401),
        ]))
        #expect(try await expired.sync(cursor: nil).status.status == .tokenExpired)
    }

    @Test func gmailPollingHistoryRelayAndExpiredCursorAreModeled() async throws {
        let tokens = MemoryTokenStore(tokens: ["gmail:me": "gmail-token"])
        let http = StubHTTPClient(responses: [
            InboxHTTPResponse(statusCode: 200, data: Data(#"{"historyId":"42","messages":[{"id":"m1"}]}"#.utf8)),
            InboxHTTPResponse(statusCode: 200, data: Data(#"{"id":"m1","threadId":"t1","internalDate":"1700000000000","labelIds":["INBOX","UNREAD"],"snippet":"Need reply","payload":{"headers":[{"name":"From","value":"sender@example.com"},{"name":"Subject","value":"Launch"}]}}"#.utf8)),
        ])
        let connector = GmailConnector(tokenStore: tokens, httpClient: http)

        let result = try await connector.sync(cursor: nil)
        #expect(result.nextCursor == "42")
        #expect(result.threads.first?.title == "Launch")
        #expect(result.items.first?.isUnread == true)
        #expect(try await connector.cursor(from: GmailPushRelayPayload(accountID: "me", historyID: "43")) == "43")

        let expired = GmailConnector(tokenStore: tokens, httpClient: StubHTTPClient(responses: [
            InboxHTTPResponse(statusCode: 404),
        ]))
        #expect(try await expired.sync(cursor: "41").status.status == .degraded)
    }

    @Test func discordGatewayMessagesReconnectAndMissingPermissionsAreModeled() async throws {
        let tokens = MemoryTokenStore(tokens: ["discord:bot": "bot-token"])
        let connector = DiscordConnector(channelIDs: ["C123"], tokenStore: tokens, httpClient: StubHTTPClient(responses: []))

        let reconnect = try await connector.parseGatewayPayload(Data(#"{"op":7}"#.utf8))
        #expect(reconnect == .reconnect)

        let invalid = try await connector.parseGatewayPayload(Data(#"{"op":9}"#.utf8))
        #expect(invalid == .invalidSession)

        let message = try await connector.parseGatewayPayload(Data(#"{"op":0,"t":"MESSAGE_CREATE","d":{"id":"m1","channel_id":"C123","timestamp":"2026-07-03T10:00:00Z","content":"@bot please check","author":{"id":"U1","username":"Casey"},"mentions":[{"id":"bot"}]}}"#.utf8))
        guard case .message(let item) = message else {
            Issue.record("Expected Discord message event")
            return
        }
        #expect(item.source == .discord)
        #expect(item.isActionable == true)

        let missingPermissions = DiscordConnector(channelIDs: ["C123"], tokenStore: tokens, httpClient: StubHTTPClient(responses: [
            InboxHTTPResponse(statusCode: 403),
        ]))
        #expect(try await missingPermissions.sync(cursor: nil).status.status == .permissionDenied)
    }
}

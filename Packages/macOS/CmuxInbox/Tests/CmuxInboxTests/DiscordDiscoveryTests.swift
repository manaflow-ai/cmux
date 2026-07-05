import CmuxInbox
import Foundation
import Testing

@Suite("Discord channel discovery")
struct DiscordDiscoveryTests {
    @Test func parseGuildsAndTextChannels() throws {
        let guilds = try DiscordConnector.parseGuilds(data: Data(#"[{"id":"G1","name":"cmux"},{"id":"G2"}]"#.utf8))
        #expect(guilds.map(\.id) == ["G1", "G2"])
        #expect(guilds[0].name == "cmux")
        #expect(guilds[1].name == "G2")

        let channels = try DiscordConnector.parseGuildTextChannels(
            data: Data(#"""
            [{"id":"C1","type":0,"name":"general"},
             {"id":"V1","type":2,"name":"voice"},
             {"id":"A1","type":5,"name":"announcements"},
             {"id":"CAT","type":4,"name":"category"}]
            """#.utf8),
            guildName: "cmux"
        )
        #expect(channels.map(\.id) == ["C1", "A1"])
        #expect(channels[0].title == "#general · cmux")
    }

    @Test func syncDiscoversChannelsSkipsForbiddenAndAdvancesSnowflakeCursor() async throws {
        let tokens = MemoryTokenStore(tokens: ["discord:bot": "bot-token"])
        let http = StubHTTPClient(responses: [
            // guilds
            InboxHTTPResponse(statusCode: 200, data: Data(#"[{"id":"G1","name":"cmux"}]"#.utf8)),
            // guild channels: two text channels
            InboxHTTPResponse(statusCode: 200, data: Data(#"[{"id":"C1","type":0,"name":"general"},{"id":"C2","type":0,"name":"private"}]"#.utf8)),
            // C1 messages
            InboxHTTPResponse(statusCode: 200, data: Data(#"[{"id":"111","channel_id":"C1","content":"hello","author":{"username":"m"},"timestamp":"2026-07-04T01:00:00.000000+00:00"}]"#.utf8)),
            // C2 messages: bot cannot read
            InboxHTTPResponse(statusCode: 403, data: Data(#"{"message":"Missing Access","code":50001}"#.utf8)),
        ])
        let connector = DiscordConnector(tokenStore: tokens, httpClient: http)

        let result = try await connector.sync(cursor: nil)
        #expect(result.status.status == .connected)
        #expect(result.items.count == 1)
        #expect(result.items.first?.bodyPreview == "hello")
        #expect(result.threads.first?.title == "#general · cmux")
        let cursors = DiscordConnector.channelCursors(from: result.nextCursor)
        #expect(cursors["C1"] == "111")
        #expect(cursors["C2"] == "0")

        // Next pass resumes from the snowflake watermark.
        let nextHTTP = StubHTTPClient(responses: [
            InboxHTTPResponse(statusCode: 200, data: Data(#"[{"id":"G1","name":"cmux"}]"#.utf8)),
            InboxHTTPResponse(statusCode: 200, data: Data(#"[{"id":"C1","type":0,"name":"general"}]"#.utf8)),
            InboxHTTPResponse(statusCode: 200, data: Data("[]".utf8)),
        ])
        let next = DiscordConnector(tokenStore: tokens, httpClient: nextHTTP)
        _ = try await next.sync(cursor: result.nextCursor)
        let urls = await nextHTTP.requestedURLs()
        #expect(urls.last?.contains("after=111") == true)
    }

    @Test func syncReportsDegradedWhenBotIsInNoServers() async throws {
        let tokens = MemoryTokenStore(tokens: ["discord:bot": "bot-token"])
        let http = StubHTTPClient(responses: [
            InboxHTTPResponse(statusCode: 200, data: Data("[]".utf8)),
        ])
        let connector = DiscordConnector(tokenStore: tokens, httpClient: http)

        let result = try await connector.sync(cursor: nil)
        #expect(result.status.status == .degraded)
        #expect(result.status.message?.contains("Invite it to a server") == true)
    }
}

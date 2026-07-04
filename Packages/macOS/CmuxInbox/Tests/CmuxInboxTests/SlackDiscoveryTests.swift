import CmuxInbox
import Foundation
import Testing

@Suite("Slack conversation discovery")
struct SlackDiscoveryTests {
    @Test func parseConversationsListLabelsChannelsAndDMs() throws {
        let json = Data(#"""
        {"ok":true,"channels":[
          {"id":"C1","name":"ops"},
          {"id":"D1","is_im":true,"user":"U9"},
          {"id":"C2"}
        ],"response_metadata":{"next_cursor":"page2"}}
        """#.utf8)
        let parsed = try SlackConnector.parseConversationsList(data: json)
        #expect(parsed.channels.map(\.id) == ["C1", "D1", "C2"])
        #expect(parsed.channels[0].title == "#ops")
        #expect(parsed.channels[1].title == "DM U9")
        #expect(parsed.channels[2].title == "#C2")
        #expect(parsed.nextCursor == "page2")
    }

    @Test func parseConversationsListEndsPaginationOnEmptyCursor() throws {
        let json = Data(#"{"ok":true,"channels":[{"id":"C1","name":"x"}],"response_metadata":{"next_cursor":""}}"#.utf8)
        #expect(try SlackConnector.parseConversationsList(data: json).nextCursor == nil)
    }

    @Test func parseConversationsListThrowsOnAuthError() {
        let json = Data(#"{"ok":false,"error":"invalid_auth"}"#.utf8)
        #expect(throws: InboxError.self) {
            _ = try SlackConnector.parseConversationsList(data: json)
        }
    }

    @Test func syncWindowPrioritizesNeverSyncedConversations() {
        let channels = (1...20).map { "C\($0)" }
        let window = SlackConnector.syncWindow(channels: channels, cursors: [:], after: nil)
        #expect(window.count == SlackConnector.historyFetchesPerSync)
        #expect(window.allSatisfy { channels.contains($0) })
        #expect(window == Array(channels.prefix(SlackConnector.historyFetchesPerSync)))
    }

    @Test func syncWindowRotatesThroughSyncedConversations() {
        let channels = (1...20).map { "C\($0)" }
        var cursors: [String: String] = [:]
        for channel in channels { cursors[channel] = "100" }
        let first = SlackConnector.syncWindow(channels: channels, cursors: cursors, after: nil)
        let second = SlackConnector.syncWindow(channels: channels, cursors: cursors, after: first.last)
        #expect(first != second)
        #expect(Set(first).isDisjoint(with: Set(second)))
    }

    @Test func syncWindowReturnsAllWhenBelowBudget() {
        let channels = ["C1", "C2", "C3"]
        #expect(SlackConnector.syncWindow(channels: channels, cursors: [:], after: nil) == channels)
    }
}

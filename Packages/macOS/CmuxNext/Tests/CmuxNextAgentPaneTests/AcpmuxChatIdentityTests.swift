import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A chat row names its chat as the session list does: the name and icon its session was given
/// (acpmux `displayName`, `icon` on `chat_value`). Leo, 2026-11-23: "the renaming paradigm still
/// hasn't hit yet, and the send/recieve messages are still only the older names."
@Suite struct AcpmuxChatIdentityTests {
    private func row(_ extra: [String: Any]) -> [String: Any] {
        var row: [String: Any] = ["key": "claude-code:s1", "sessionId": "s1", "harness": "claude-code",
                                  "title": "coord-old", "updatedMs": 1000]
        row.merge(extra) { _, new in new }
        return row
    }

    @Test func aRowCarriesItsSessionsGivenNameAndIcon() throws {
        let chat = try #require(AcpmuxChat(json: row([
            "displayName": "Mango",
            "icon": ["kind": "emoji", "text": "🥭", "source": "session"],
        ])))
        #expect(chat.displayName == "Mango")
        #expect(chat.icon == AcpmuxChat.Icon(kind: "emoji", value: "🥭"))
        #expect(chat.matches("mango"), "the given name finds the chat")

        let symbol = try #require(AcpmuxChat(json: row([
            "icon": ["kind": "symbol", "name": "leaf", "text": "M", "hue": 30],
        ])))
        #expect(symbol.icon == AcpmuxChat.Icon(kind: "symbol", value: "leaf", text: "M", hue: 30))
    }

    @Test func aRowWithoutOneReadsAsBefore() throws {
        let chat = try #require(AcpmuxChat(json: row(["displayName": NSNull(), "icon": NSNull()])))
        #expect(chat.displayName == nil)
        #expect(chat.icon == nil)
        let older = try #require(AcpmuxChat(json: row([:])))
        #expect(older.displayName == nil && older.icon == nil)
    }
}

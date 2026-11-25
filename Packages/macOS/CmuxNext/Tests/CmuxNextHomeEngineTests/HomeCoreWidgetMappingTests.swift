import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextHomeEngine

/// Chat widgets are gone (user, Nov 9: "remove widgets completely"). A `widget` part the local
/// owner stored before shows in Home as its plain fallback text, never a card.
struct HomeCoreWidgetMappingTests {
    func decoded(_ json: String) throws -> ConversationPart {
        try JSONDecoder().decode(ConversationPart.self, from: Data(json.utf8))
    }

    @Test func aStoredWidgetPartShowsAsItsFallbackText() throws {
        let part = try decoded("""
        {"type": "widget", "app": "cmux/pr-card", "widget": "cmux.chat.widget/1",
         "props": {"repo": "manaflow-ai/cmux", "number": 38629},
         "fallback": "PR #38629: open, checks passing", "url": "https://github.com/manaflow-ai/cmux/pull/38629"}
        """)
        let mapped = HomeCoreMapping.part(part, messageID: "msg_1", index: 0)
        #expect(mapped == .text("PR #38629: open, checks passing", mentions: []))
    }

    @Test func aWidgetPartWithoutAFallbackShowsItsLink() throws {
        let part = try decoded(#"{"type": "widget", "url": "https://example.com/a"}"#)
        #expect(HomeCoreMapping.part(part) == .text("https://example.com/a", mentions: []))
    }
}

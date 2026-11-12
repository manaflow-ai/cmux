import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextHomeEngine

struct HomeCoreWidgetMappingTests {
    func decoded(_ json: String) throws -> ConversationPart {
        try JSONDecoder().decode(ConversationPart.self, from: Data(json.utf8))
    }

    @Test func theLocalOwnersWidgetPartBecomesAHomeWidget() throws {
        let part = try decoded("""
        {"type": "widget", "app": "cmux/pr-card", "widget": "cmux.chat.widget/1",
         "props": {"repo": "manaflow-ai/cmux", "number": 38629},
         "fallback": "PR #38629: open, checks passing", "url": "https://github.com/manaflow-ai/cmux/pull/38629"}
        """)
        let mapped = HomeCoreMapping.part(part, messageID: "msg_1", index: 0)
        guard case .widget(let widget) = mapped else {
            Issue.record("expected a widget, got \(mapped)")
            return
        }
        #expect(widget.app == "cmux/pr-card")
        #expect(widget.propsJSON == #"{"number":38629,"repo":"manaflow-ai/cmux"}"#)
        #expect(widget.fallback == "PR #38629: open, checks passing")
        #expect(widget.url == "https://github.com/manaflow-ai/cmux/pull/38629")
        #expect(mapped.plainText == "PR #38629: open, checks passing")
    }

    @Test func aWidgetPartWithoutAnAppShowsItsLink() throws {
        let part = try decoded(#"{"type": "widget", "fallback": "x", "url": "https://example.com/a"}"#)
        #expect(HomeCoreMapping.part(part) == .text("https://example.com/a", mentions: []))
    }
}

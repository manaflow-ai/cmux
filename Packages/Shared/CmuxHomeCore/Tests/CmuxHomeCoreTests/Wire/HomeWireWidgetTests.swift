import Foundation
import Testing
@testable import CmuxHomeCore

/// Widget parts on the wire (plans/cmux-next/chat-widgets-DESIGN.md section 3).
@Suite struct HomeWireWidgetTests {
    let mapping = HomeWireMapping()

    @Test func aWidgetPartBecomesAWidgetWithItsPropsAndFallback() throws {
        let json = try #require(HomeWireJSON.parse("""
            {"type": "widget", "app": "cmux/pr-card", "widget": "cmux.chat.widget/1",
             "props": {"repo": "manaflow-ai/cmux", "number": 38629},
             "fallback": "PR #38629: Model picker", "url": "https://github.com/manaflow-ai/cmux/pull/38629"}
            """))
        let part = mapping.part(json, messageID: "msg_1", index: 0)
        guard case .widget(let widget) = part else {
            Issue.record("not a widget: \(part)")
            return
        }
        #expect(widget.app == "cmux/pr-card")
        #expect(widget.url == "https://github.com/manaflow-ai/cmux/pull/38629")
        let props = try #require(HomeWireJSON.parse(widget.propsJSON))
        #expect(props["number"].int == 38629)
        #expect(part.plainText == "PR #38629: Model picker")
    }

    @Test func aWidgetWithoutAnAppShowsItsFallbackText() throws {
        let json = try #require(HomeWireJSON.parse(#"{"type": "widget", "fallback": "Build green"}"#))
        #expect(mapping.part(json, messageID: "msg_1", index: 0) == .text("Build green"))
    }
}

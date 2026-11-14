import Foundation
import Testing
@testable import CmuxHomeCore

/// Chat widgets are gone (user, Nov 9: "remove widgets completely"). A message that an
/// older build stored with a `widget` part still shows: as its plain fallback text.
@Suite struct HomeWireWidgetTests {
    let mapping = HomeWireMapping()

    @Test func aStoredWidgetPartShowsAsItsFallbackText() throws {
        let json = try #require(HomeWireJSON.parse("""
            {"type": "widget", "app": "cmux/pr-card", "widget": "cmux.chat.widget/1",
             "props": {"repo": "manaflow-ai/cmux", "number": 38629},
             "fallback": "PR #38629: Model picker", "url": "https://github.com/manaflow-ai/cmux/pull/38629"}
            """))
        let part = mapping.part(json, messageID: "msg_1", index: 0)
        #expect(part == .text("PR #38629: Model picker"))
        #expect(part.plainText == "PR #38629: Model picker")
    }

    @Test func aWidgetWithoutAnAppShowsItsFallbackText() throws {
        let json = try #require(HomeWireJSON.parse(#"{"type": "widget", "fallback": "Build green"}"#))
        #expect(mapping.part(json, messageID: "msg_1", index: 0) == .text("Build green"))
    }
}

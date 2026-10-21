import Foundation
import Testing
@testable import CmuxNextDaemon

/// A group's "Chiefs Reply" setting on the wire (plans/cmux-next/chief-group-chats-DESIGN.md):
/// the Mac sends it as `conversation.settings.set {wake_policy}` through `cloud-conversation-op`
/// and reads it back from the head's `settings`.
struct CloudChiefRepliesWireTests {
    @Test func theSettingIsAConversationSettingsOp() throws {
        let op = CloudConversationOp.setSettings(wakePolicy: "all")
        #expect(op.kindName == "conversation.settings.set")
        let json = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encoder().encode(op))
        #expect(json == .object(["kind": .string("conversation.settings.set"), "wake_policy": .string("all")]))
    }

    @Test func aHeadCarriesItsWakePolicy() throws {
        let head = Data(#"""
        {"id":"conv_A","owner":"cloud","title":"","participants":[],"last_seq":3,"rev":4,"created_at":"2026-10-20T00:00:00.000Z","updated_at":"2026-10-20T00:00:00.000Z","kind":"group","settings":{"wake_policy":"mentions","agent_budget":{"turns":6,"gap_ms":2000},"history_visible":"all"}}
        """#.utf8)
        let summary = try JSONDecoder().decode(ConversationSummary.self, from: head)
        #expect(summary.wakePolicy == "mentions")
    }

    @Test func aHeadWithoutSettingsHasNone() throws {
        let head = Data(#"""
        {"id":"conv_B","title":"","participants":[],"last_seq":0,"rev":1,"created_at":"x","updated_at":"x"}
        """#.utf8)
        let summary = try JSONDecoder().decode(ConversationSummary.self, from: head)
        #expect(summary.wakePolicy == nil)
    }
}

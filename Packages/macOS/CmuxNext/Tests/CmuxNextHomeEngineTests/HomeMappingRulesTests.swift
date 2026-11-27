import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextHomeEngine

/// The `mapping.*` ops through the FFI (smoke: the rules' cases live in cmux-home-rules'
/// `tests/mapping_*.rs`).
struct HomeMappingRulesTests {
    @Test func aCloudMessageMapsThroughTheRules() throws {
        let wire = try JSONDecoder().decode(ConversationMessage.self, from: Data("""
        {"id": "msg_1", "conversation": "conv_1", "seq": 7, "client_msg_id": "c1", "author": "user_worker",
         "created_at": "2026-11-26T10:00:00Z",
         "parts": [
           {"type": "text", "text": "hi @me", "mentions": [{"start": 3, "length": 3, "participant": "user_worker"}]},
           {"type": "question", "session": "s1", "items": [{"id": "q1", "prompt": "Ship?", "options": [{"id": "y", "label": "Yes"}]}]},
           {"type": "widget", "fallback": "PR #1: open", "url": "https://example.com/1"}
         ]}
        """.utf8))
        let identity = CloudIdentity(stackUserID: "worker", displayName: "Me", localID: ParticipantID("user_local"))
        let message = HomeCoreMapping.message(wire, identity: identity)
        #expect(message.id == MessageID("msg_1"))
        #expect(message.seq == 7)
        #expect(message.author == ParticipantID("user_local"))
        #expect(message.createdAt == Date(timeIntervalSince1970: 1_795_687_200))
        #expect(message.parts.count == 3)
        #expect(message.parts[0] == .text("hi @me", mentions: [Mention(start: 3, length: 3, participant: ParticipantID("user_local"))]))
        guard case .question = message.parts[1] else {
            Issue.record("a question part maps to .question, got \(message.parts[1])")
            return
        }
        #expect(message.parts[2] == .text("PR #1: open", mentions: []))
    }
}

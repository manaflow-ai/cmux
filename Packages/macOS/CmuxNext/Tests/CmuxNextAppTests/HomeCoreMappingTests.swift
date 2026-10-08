import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The local owner's wire types as the shared Home core's types
/// (plans/cmux-next/home-mac.md): the mux is the Chief, text keeps its
/// mentions, and a send keeps the intent's key as the owner's client id.
@Suite struct HomeCoreMappingTests {
    @Test func theLocalMuxIsTheChiefAndTimesParse() {
        let mux = ConversationParticipant(id: "agent_mux", kind: .agent, displayName: "Chief", agentClass: "mux", acpSession: "mux")
        let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")
        let summary = CmuxNextDaemon.ConversationSummary(id: "conv_01", title: "", participants: [me, mux], lastSeq: 3, rev: 4,
                                                         createdAt: "2026-10-02T12:00:00.000Z", updatedAt: "2026-10-02T12:00:05.000Z",
                                                         lastMessage: nil, readCursors: ["user_local": 2])
        let mapped = HomeCoreMapping.summary(summary)
        #expect(mapped.owner == .local)
        #expect(mapped.kind(me: ParticipantID("user_local")) == .chief)
        #expect(mapped.unreadCount(me: ParticipantID("user_local")) == 1)
        #expect(mapped.updatedAt.timeIntervalSince(mapped.createdAt) == 5)
    }

    @Test func aSendKeepsTheKeyAndTheMentions() throws {
        let key = IdempotencyKey("cmk_test")
        let op = HomeOp.sendMessage(conversation: ConversationID("conv_01"),
                                    parts: [.text("@Chief hi", mentions: [Mention(start: 0, length: 6, participant: ParticipantID("agent_mux"))])])
        let mapped = try #require(HomeCoreMapping.op(op, key: key))
        #expect(mapped.conversation == "conv_01")
        guard case .send(let clientMsgID, let parts, nil) = mapped.op else { Issue.record("not a send"); return }
        #expect(clientMsgID == "cmk_test")
        #expect(parts == [.text("@Chief hi", runs: [ConversationTextRun(start: 0, length: 6, mention: "agent_mux")])])
        #expect(HomeCoreMapping.op(.createChief(name: "x"), key: key) == nil)
    }

    /// An image part of the local owner is a Home attachment (not the text
    /// "attachment"), and a Home send with an attachment keeps it as an
    /// attachment part on the wire, with its preview.
    @Test func attachmentPartsMapBothWays() throws {
        let hash = String(repeating: "a", count: 64), preview = String(repeating: "b", count: 64)
        let json = #"""
        {"id":"msg_1","conversation":"conv_A","seq":1,"client_msg_id":"c1","author":"user_local","created_at":"2026-10-05T12:00:00.000Z",
         "parts":[{"type":"attachment","hash":"\#(hash)","name":"shot.png","mime_type":"image/png","byte_count":1234,"width":640,"height":480,
                   "preview":{"hash":"\#(preview)","mime_type":"image/jpeg","byte_count":99}},{"type":"text","text":"what does this say?"}],
         "reactions":[]}
        """#
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        let ref = AttachmentRef(hash: hash, name: "shot.png", mimeType: "image/png", byteCount: 1234, width: 640, height: 480,
                                preview: AttachmentDerivedImage(hash: preview, mimeType: "image/jpeg", byteCount: 99))
        #expect(HomeCoreMapping.message(message).parts == [.attachment(ref), .text("what does this say?")])

        let op = HomeOp.sendMessage(conversation: ConversationID("conv_A"), parts: [.attachment(ref), .text("what does this say?")])
        let mapped = try #require(HomeCoreMapping.op(op, key: IdempotencyKey("c1")))
        guard case .send(_, let parts, nil) = mapped.op else { Issue.record("not a send"); return }
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(parts)) as? [[String: Any]])
        #expect(wire.first?["type"] as? String == "attachment")
        #expect(wire.first?["hash"] as? String == hash)
        #expect(wire.first?["mime_type"] as? String == "image/png")
        #expect(wire.first?["byte_count"] as? Int == 1234)
        #expect((wire.first?["preview"] as? [String: Any])?["hash"] as? String == preview)
        #expect(wire.last?["type"] as? String == "text")
    }
}

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
}

import Foundation
import Testing
@testable import CmuxNextDaemon

/// Wire shapes of `local-conversations-v1` (plans/cmux-next/home.md section 2).
@Suite struct ConversationWireTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func sendOpEncodesTheContractShape() throws {
        let request = ConversationOpRequest(
            conversation: "conv_A", idempotencyKey: "c1", actor: "user_local", transaction: ClientTransactionID("t1"),
            op: .send(clientMsgID: "c1", parts: [.text("hi @mux", runs: [ConversationTextRun(start: 3, length: 4, mention: "agent_mux")])],
                      replyTo: nil))
        let object = try object(request)
        #expect(object["cmd"] == .string("conversation-op"))
        #expect(object["idempotency_key"] == .string("c1"))
        #expect(object["transaction"] == .string("t1"))
        guard case .object(let op) = object["op"] else { Issue.record("op missing"); return }
        #expect(op["kind"] == .string("message.send"))
        #expect(op["client_msg_id"] == .string("c1"))
        guard case .array(let parts) = op["parts"], case .object(let part) = parts.first else { Issue.record("parts"); return }
        #expect(part["type"] == .string("text"))
        guard case .array(let runs) = part["runs"], case .object(let run) = runs.first else { Issue.record("runs"); return }
        #expect(run["mention"] == .string("agent_mux"))
    }

    @Test func reactionOpNamesTheReactionField() throws {
        let request = ConversationOpRequest(conversation: "conv_A", idempotencyKey: "r1", actor: "user_local", transaction: nil,
                                            op: .addReaction(messageID: "msg_1", partIndex: 0, kind: .tapback("love")))
        guard case .object(let op) = try object(request)["op"] else { Issue.record("op missing"); return }
        #expect(op["kind"] == .string("reaction.add"))
        #expect(op["reaction"] == .object(["tapback": .string("love")]))
        #expect(op["part_index"] == .number(0))
    }

    @Test func historyAndSnapshotClampTheirLimits() throws {
        #expect(try object(ConversationHistoryRequest(conversation: "c", beforeSeq: 10, limit: 9000))["limit"] == .number(500))
        #expect(try object(ConversationSnapshotRequest(conversation: "c", tail: 0))["tail"] == .number(1))
        #expect(try object(ConversationHistoryRequest(conversation: "c", beforeSeq: 10, limit: 5))["before_seq"] == .number(10))
    }

    @Test func eventsDecodeIntoConversationCases() {
        let line = #"""
        {"event":"conversation-changed","conversation":"conv_A","rev":4,"transaction":"t1","change":{"kind":"message","message":
        {"id":"msg_1","conversation":"conv_A","seq":3,"client_msg_id":"c1","author":"user_local","created_at":"2026-10-01T12:00:00.000Z",
         "parts":[{"type":"text","text":"hi"},{"type":"work","session":"child","status":"done","preview":"ok"},{"type":"poll","question":"?"}],
         "reactions":[{"author":"agent_mux","part_index":0,"kind":{"tapback":"like"},"at":"2026-10-01T12:00:01.000Z"}]}}}
        """#
        let event = DaemonEvent.decode(name: "conversation-changed", line: Data(line.utf8))
        guard case .conversationChanged(let changed) = event, case .message(let message) = changed.change else {
            Issue.record("decoded \(event)")
            return
        }
        #expect(changed.rev == 4)
        #expect(event.clientTransactionID == ClientTransactionID("t1"))
        #expect(message.parts.count == 3)
        #expect(message.parts[1] == .work(session: "child", host: nil, status: "done", preview: "ok"))
        if case .unknown(let type, _) = message.parts[2] { #expect(type == "poll") } else { Issue.record("unknown part") }
        #expect(message.reactions.first?.kind == .tapback("like"))

        let typing = DaemonEvent.decode(name: "conversation-typing",
                                        line: Data(#"{"event":"conversation-typing","conversation":"conv_A","participant":"agent_mux","on":true}"#.utf8))
        #expect(typing == .conversationTyping(ConversationTyping(conversation: "conv_A", participant: "agent_mux", on: true)))
    }

    @Test func summaryDecodesWithOptionalFieldsMissing() throws {
        let json = #"""
        {"id":"conv_A","title":"mux","participants":[{"id":"agent_mux","kind":"agent","display_name":"mux","agent_class":"mux","acp_session":"mux"}],
         "last_seq":7,"rev":9,"created_at":"2026-10-01T12:00:00.000Z","updated_at":"2026-10-01T12:00:00.000Z","read_cursors":{"user_local":5}}
        """#
        let summary = try JSONDecoder().decode(ConversationSummary.self, from: Data(json.utf8))
        #expect(summary.owner == "local")
        #expect(summary.participants.first?.agentClass == "mux")
        #expect(summary.unreadCount(for: ConversationParticipant.localUserID) == 2)
        #expect(summary.unreadCount(for: "agent_mux") == 7)
    }
}

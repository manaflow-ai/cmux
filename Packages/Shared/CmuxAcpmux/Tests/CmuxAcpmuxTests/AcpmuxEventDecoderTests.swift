import CmuxAcpmux
import CmuxConversation
import Foundation
import Testing

struct AcpmuxEventDecoderTests {
    let decoder = AcpmuxEventDecoder()

    func record(_ json: String) throws -> AcpmuxRecord {
        try #require(AcpmuxRecord(event: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
    }

    @Test func liveUpdatesAndHistoryRecordsDecodeTheSame() throws {
        let params = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}},"_meta":{"acpmux":{"seq":7,"at":1000}}}"#.utf8))
        let live = try #require(AcpmuxRecord(update: params))
        let history = try record(#"{"sessionId":"s","seq":7,"at":1000,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"sessionId":"agent-sid","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}}"#)
        #expect(decoder.decode(live)?.event == .assistantText("hi"))
        #expect(decoder.decode(live)?.event == decoder.decode(history)?.event)
        #expect(decoder.decode(live)?.cursor.order == 7)
    }

    @Test func queueAndAttachmentRecords() throws {
        let queued = try record(#"{"seq":3,"dir":"mux","kind":"queued","msg":{"text":"read","clientMessageId":"c1","position":2,"held":true,"attachments":[{"uploadId":"u1","name":"a.pdf","mimeType":"application/pdf","size":10,"sha256":"ab"}]}}"#)
        guard case let .userMessageQueued(id, text, atts, pos, held)? = decoder.decode(queued)?.event else { Issue.record("not queued"); return }
        #expect(id == ClientMessageID("c1") && text == "read" && pos == 2 && held && atts.first?.name == "a.pdf")

        let failed = try record(#"{"seq":9,"dir":"mux","kind":"attachment","msg":{"uploadId":"u1","name":"a.pdf","mimeType":"application/pdf","size":10,"sha256":"ab","state":"failed","received":4}}"#)
        guard case let .attachmentChanged(a)? = decoder.decode(failed)?.event else { Issue.record("not attachment"); return }
        #expect(a.state == .failed)

        let queue = try record(#"{"seq":4,"dir":"mux","kind":"queue","msg":{"entries":[{"position":1,"ticket":5,"clientMessageId":"c2"}]}}"#)
        #expect(decoder.decode(queue)?.event == .queueChanged([QueuedPrompt(clientMessageID: ClientMessageID("c2"), position: 1, ticket: 5)]))
    }

    @Test func permissionsAndTurns() throws {
        let ask = try record(#"{"seq":5,"dir":"mux","kind":"permission_request","msg":{"permissionId":"p","request":{"toolCall":{"title":"rm -rf x"},"options":[{"optionId":"y","name":"Allow","kind":"allow_once"}]}}}"#)
        guard case let .approvalRequested(r)? = decoder.decode(ask)?.event else { Issue.record("not approval"); return }
        #expect(r.title == "rm -rf x" && r.options.first?.isApproval == true)
        let decided = try record(#"{"seq":6,"dir":"mux","kind":"permission_decision","msg":{"permissionId":"p","outcome":{"outcome":"selected","optionId":"y"}}}"#)
        #expect(decoder.decode(decided)?.event == .approvalResolved(id: "p", optionID: "y"))
        let failedTurn = try record(#"{"seq":8,"dir":"mux","kind":"turn_result","msg":{"status":"failed","error":"boom"}}"#)
        #expect(decoder.decode(failedTurn)?.event == .turnEnded(stopReason: "failed", error: "boom"))
    }

    @Test func replaysAndUnknownRecordsAreSkipped() throws {
        #expect(decoder.decode(try record(#"{"seq":1,"dir":"in","kind":"agent_message_chunk.replay","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"old"}}}}}"#)) == nil)
        #expect(decoder.decode(try record(#"{"seq":2,"dir":"mux","kind":"stderr","msg":{"text":"noise"}}"#)) == nil)
        #expect(decoder.decode(try record(#"{"seq":3,"dir":"out","kind":"session/prompt","msg":{}}"#)) == nil)
    }
}

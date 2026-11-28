import Foundation
import Testing
@testable import CmuxNextDaemon

/// `conversation-thread` is generated from the schema (bindings.json `clamp`): the same bytes, gate and
/// 1...500 clamp the hand-written type had. Only the init clamps; a later assignment is sent as assigned.
struct ConversationThreadRequestWireTests {
    static func line(_ request: ConversationThreadRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    @Test func theWireIsTheHandWrittenOne() throws {
        let request = ConversationThreadRequest(conversation: "c1", root: "m1", afterSeq: 0, limit: 50)
        #expect(try Self.line(request)
            == #"{"after_seq":0,"cmd":"conversation-thread","conversation":"c1","id":7,"limit":50,"root":"m1"}"#)
        #expect(ConversationThreadRequest.command == "conversation-thread")
        #expect(ConversationThreadRequest.requiredCapability == DaemonCapability.conversationThread.rawValue)
        #expect(ConversationThreadRequest.maxLimit == 500)
    }

    @Test func theInitClampsTheLimitToOneThroughFiveHundred() {
        #expect(ConversationThreadRequest(conversation: "c", root: "r", afterSeq: 3, limit: 0).limit == 1)
        #expect(ConversationThreadRequest(conversation: "c", root: "r", afterSeq: 3, limit: -9).limit == 1)
        #expect(ConversationThreadRequest(conversation: "c", root: "r", afterSeq: 3, limit: 500).limit == 500)
        #expect(ConversationThreadRequest(conversation: "c", root: "r", afterSeq: 3, limit: 9_000).limit == 500)
    }

    @Test func anAssignmentAfterInitIsSentAsAssigned() throws {
        var request = ConversationThreadRequest(conversation: "c", root: "r", afterSeq: 3, limit: 10)
        request.limit = 900
        request.afterSeq = 4
        #expect(request.limit == 900)
        #expect(try Self.line(request)
            == #"{"after_seq":4,"cmd":"conversation-thread","conversation":"c","id":7,"limit":900,"root":"r"}"#)
    }
}

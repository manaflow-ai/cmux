import Testing
@testable import CmuxNextDaemon

struct ConversationReadRequestClampTests {
    @Test func initializerClampsPreserveRequestBytes() throws {
        #expect(ConversationSnapshotRequest.requiredCapability == DaemonCapability.localConversations.rawValue)
        #expect(ConversationHistoryRequest.requiredCapability == DaemonCapability.localConversations.rawValue)

        for (input, expected) in [(Int.min, 1), (1, 1), (29, 29), (500, 500), (Int.max, 500)] {
            let snapshot = ConversationSnapshotRequest(conversation: "c/1", tail: input)
            let history = ConversationHistoryRequest(conversation: "c/1", beforeSeq: .max, limit: input)
            #expect(snapshot.tail == expected)
            #expect(history.limit == expected)
            #expect(try String(decoding: WireCoding.encodeRequest(snapshot, id: nil), as: UTF8.self)
                == #"{"cmd":"conversation-snapshot","conversation":"c/1","tail":\#(expected)}"#)
            #expect(try String(decoding: WireCoding.encodeRequest(history, id: 7), as: UTF8.self)
                == #"{"before_seq":18446744073709551615,"cmd":"conversation-history","conversation":"c/1","id":7,"limit":\#(expected)}"#)
        }
    }

    @Test func assigningAfterInitSendsTheValueUnclamped() throws {
        var snapshot = ConversationSnapshotRequest(conversation: "c", tail: 1)
        var history = ConversationHistoryRequest(conversation: "c", beforeSeq: 0, limit: 500)
        for value in [-1, 501] {
            snapshot.tail = value
            history.limit = value
            #expect(try String(decoding: WireCoding.encodeRequest(snapshot, id: 3), as: UTF8.self)
                == #"{"cmd":"conversation-snapshot","conversation":"c","id":3,"tail":\#(value)}"#)
            #expect(try String(decoding: WireCoding.encodeRequest(history, id: nil), as: UTF8.self)
                == #"{"before_seq":0,"cmd":"conversation-history","conversation":"c","limit":\#(value)}"#)
        }
    }
}

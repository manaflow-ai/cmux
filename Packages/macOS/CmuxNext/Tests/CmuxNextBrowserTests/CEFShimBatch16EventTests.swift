import Foundation
import Testing
@testable import CmuxNextBrowser

/// The cmux.16 shim events (raw DevTools messages, preference changes) and
/// the DevTools message id rule, without starting CEF.
@Suite struct CEFShimBatch16EventTests {
    @Test func decodesARawDevToolsMessage() {
        let json = #"{"id":1073741824,"result":{}}"#
        let event = CEFShimEvent(kind: 32, browser: 7, request: 0, a: 0, b: 0, s1: json, s2: "")
        #expect(event == .devToolsMessage(browser: 7, json: json))
        #expect(event.browserID == 7)
    }

    @Test func decodesAPreferenceChange() {
        let event = CEFShimEvent(kind: 33, browser: 0, request: 0, a: 0, b: 0,
                                 s1: "credentials_enable_service", s2: "/profiles/a")
        #expect(event == .preferenceChanged(name: "credentials_enable_service", profilePath: "/profiles/a"))
        #expect(event.browserID == nil)
    }

    /// Raw sends use ids from 2^30 up; the shim's own calls stay below.
    @Test func rawSendIdsStartAtTwoToTheThirty() {
        #expect(CEFDevToolsRawMessage.firstRawID == 1_073_741_824)
        #expect(CEFDevToolsRawMessage.isRawID(1_073_741_824))
        #expect(CEFDevToolsRawMessage.isRawID(Int(Int32.max)))
        #expect(!CEFDevToolsRawMessage.isRawID(1_073_741_823))
        #expect(!CEFDevToolsRawMessage.isRawID(1))
        #expect(!CEFDevToolsRawMessage.isRawID(0))
        #expect(!CEFDevToolsRawMessage.isRawID(-1))
        #expect(!CEFDevToolsRawMessage.isRawID(Int(Int32.max) + 1))
    }

    @Test func findsTheReplyIdOfARawMessage() {
        #expect(CEFDevToolsRawMessage.replyID(in: #"{"id":1073741830,"result":{}}"#) == 1_073_741_830)
        #expect(CEFDevToolsRawMessage.replyID(in: #"{"sessionId":"S","id":1073741831,"error":{}}"#) == 1_073_741_831)
        // An event has no id; a shim-internal reply is not a raw reply.
        #expect(CEFDevToolsRawMessage.replyID(in: #"{"method":"Page.loadEventFired","params":{}}"#) == nil)
        #expect(CEFDevToolsRawMessage.replyID(in: #"{"id":12,"result":{}}"#) == nil)
        #expect(CEFDevToolsRawMessage.replyID(in: #"{"id":1073741824.5}"#) == nil)
        #expect(CEFDevToolsRawMessage.replyID(in: "not json") == nil)
        // No full parse: a lone surrogate in a value or deep nesting still
        // finds the reply id; a repeated "id" is refused (review P2/P3).
        #expect(CEFDevToolsRawMessage.replyID(in: #"{"id":1073741832,"result":{"value":"\ud800"}}"#) == 1_073_741_832)
        #expect(CEFDevToolsRawMessage.replyID(in: #"{"id":1073741833,"result":"# + String(repeating: "[", count: 300) + String(repeating: "]", count: 300) + "}") == 1_073_741_833)
        #expect(CEFDevToolsRawMessage.replyID(in: #"{"id":5,"id":1073741824}"#) == nil)
        #expect(CEFDevToolsRawMessage.replyID(in: #"{"method":"M","params":{"id":1073741824}}"#) == nil)
    }
}

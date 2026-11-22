import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextBrowserHost

/// The host's small CDP ids move into the shim's raw range (>= 2^30) and
/// back; events, sessionId and every other byte pass unchanged.
@Suite struct CDPRawIDMapTests {
    @Test func commandsGetRawIDsAndRepliesGetTheHostIDBack() throws {
        var map = CDPRawIDMap()
        let firstOut = map.outbound(#"{"id":1,"method":"Page.enable","sessionId":"S1"}"#)
        let first = try #require(firstOut)
        #expect(first.message == #"{"id":1073741824,"method":"Page.enable","sessionId":"S1"}"#)
        #expect(first.rawID == 1 << 30 && first.hostID == 1)
        let secondOut = map.outbound(#"{ "method":"Runtime.enable", "id" : 2 }"#)
        let second = try #require(secondOut)
        #expect(second.message == #"{ "method":"Runtime.enable", "id" : 1073741825 }"#)

        // Replies may come in any order; sessionId and nested ids stay.
        let secondReply = map.inbound(#"{"id":1073741825,"result":{"id":5}}"#)
        let firstReply = map.inbound(#"{"sessionId":"S1","id":1073741824,"result":{}}"#)
        #expect(secondReply == #"{"id":2,"result":{"id":5}}"#)
        #expect(firstReply == #"{"sessionId":"S1","id":1,"result":{}}"#)
        #expect(map.pending.isEmpty)
    }

    @Test func eventsPassAndUnknownRepliesDrop() {
        var map = CDPRawIDMap()
        let event = #"{"method":"Page.loadEventFired","params":{"timestamp":1},"sessionId":"S"}"#
        let passed = map.inbound(event)
        #expect(passed == event)
        // A raw reply the host never asked for, and a shim-internal id.
        let unknown = map.inbound(#"{"id":1073741999,"result":{}}"#)
        let internalID = map.inbound(#"{"id":12,"result":{}}"#)
        let noID = map.outbound(#"{"method":"Page.enable"}"#)
        #expect(unknown == nil)
        #expect(internalID == nil)
        #expect(noID == nil)
    }

    @Test func aForgottenCommandFreesItsID() throws {
        var map = CDPRawIDMap()
        let sentOut = map.outbound(#"{"id":9,"method":"M"}"#)
        let sent = try #require(sentOut)
        map.forget(rawID: sent.rawID)
        let late = map.inbound(#"{"id":\#(sent.rawID),"result":{}}"#)
        #expect(late == nil)
    }

    @Test func errorRepliesKeepTheHostIDAndSession() throws {
        let reply = try #require(CDPRawIDMap.errorReply(to: #"{"id":4,"method":"M","sessionId":"S2"}"#, text: "no page"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(object["id"] as? Int == 4)
        #expect(object["sessionId"] as? String == "S2")
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32000)
        #expect(error["message"] as? String == "no page")
    }

    @Test func idReplacementScansOnlyTheTopLevel() {
        #expect(CEFDevToolsRawMessage.replacingTopLevelID(in: #"{"params":{"id":3},"id":-7}"#, with: 1 << 30)
            == #"{"params":{"id":3},"id":1073741824}"#)
        #expect(CEFDevToolsRawMessage.replacingTopLevelID(in: #"{"id":1,"id":2}"#, with: 5) == nil)
        #expect(CEFDevToolsRawMessage.replacingTopLevelID(in: #"{"method":"M"}"#, with: 5) == nil)
        #expect(CEFDevToolsRawMessage.topLevelID(in: #"{"id":12,"result":{"v":"\ud800"}}"#) == 12)
    }
}

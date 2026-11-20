import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxRequestIdsTests {
    @Test func opaqueNotificationKeepsWireTextAndSkipsFoundationParse() throws {
        let text = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(let forwarded, let object, let method) = ids.toPage(text) else {
            Issue.record("notification was not forwarded")
            return
        }
        #expect(forwarded == text)
        #expect(object == nil)
        #expect(method == nil)
    }

    @Test func observerNotificationKeepsWireTextButProvidesParsedObject() throws {
        let text = #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p"}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(let forwarded, let object, let method) = ids.toPage(text) else {
            Issue.record("observer notification was not forwarded")
            return
        }
        #expect(forwarded == text)
        #expect(method == "_acpmux/permission_pending")
        #expect((object?["params"] as? [String: Any])?["permissionId"] as? String == "p")
    }

    @Test func observerMethodValueIsUsedInsteadOfSubstringMarkers() throws {
        let text = #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"message":"_acpmux/event"}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(_, let object, let method) = ids.toPage(text) else {
            Issue.record("observer notification was not forwarded")
            return
        }
        #expect(method == "_acpmux/permission_pending")
        #expect(object != nil)
    }

    @Test func escapedObserverMethodValueStillFeedsObservers() throws {
        let text = #"{"jsonrpc":"2.0","method":"_acpmux\/permission_pending","params":{"sessionId":"s","permissionId":"p"}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(_, let object, let method) = ids.toPage(text) else {
            Issue.record("escaped observer notification was not forwarded")
            return
        }
        #expect(method == "_acpmux/permission_pending")
        #expect(object != nil)
    }

    @Test func escapedObserverMethodKeyStillFeedsObservers() throws {
        let text = #"{"jsonrpc":"2.0","\u006det\u0068od":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p"}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(_, let object, let method) = ids.toPage(text) else {
            Issue.record("escaped observer method key was not forwarded")
            return
        }
        #expect(method == "_acpmux/permission_pending")
        #expect(object != nil)
    }

    @Test func replyWithMethodInResultStillRewritesItsId() throws {
        let text = #"{"jsonrpc":"2.0","id":1,"result":{"value":"method","nested":{"method":"opaque"}}}"#
        let ids = AcpmuxRequestIds()
        let relay = try #require(ids.begin(pageID: "7", method: "_acpmux/status"))
        guard case .page(let forwarded, let object, let method) = ids.toPage(text) else {
            Issue.record("reply was mistaken for a notification")
            return
        }
        #expect(method == "_acpmux/status")
        #expect(object?["id"] as? Int == 7)
        #expect(forwarded.contains(#""id":7"#))
        #expect(relay == 1)
    }
}

import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A peer chat whose machine is down paints from this Mac's copy of it (webviews direct.ts
/// drawPeerCopy, peerCopy.ts; acpmux `_acpmux/peer_snapshot`). A fleet capture of the real app
/// found the relay refused that read ("Refused by the cmux host", `methodRefused`), so the pane
/// showed an empty Failed chat with no offline banner. At the relay boundary (the page's frames
/// into ``AgentPaneTransport``, out to acpmux): the read goes out with the chat's id and nothing
/// else, before the attach brings the chat into the pane's scope.
@Suite(.serialized)
@MainActor
struct AgentPanePeerSnapshotRelayTests {
    static func read(id: Int, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/peer_snapshot","params":\#(params)}"#
    }

    @Test func thePaneMaySendPeerReconnectForTheNamedMachineOnly() throws {
        let frame = #"{"jsonrpc":"2.0","id":1,"method":"_acpmux/peer_reconnect","params":{"name":"huge-blue","wait":true}}"#
        guard case .send = AcpmuxPaneMethods.decide(frame, isFirst: false, localAppToken: nil) else {
            Issue.record("the relay refused the pane's _acpmux/peer_reconnect")
            return
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
        #expect(!AcpmuxPaneMethods.breaksParamsRule(object, modeFields: []))
        for extra in [#""sessionId":"s""#, #""url":"ssh://host""#, #""token":"secret""#] {
            let invalid = #"{"jsonrpc":"2.0","id":1,"method":"_acpmux/peer_reconnect","params":{"name":"huge-blue","wait":true,\#(extra)}}"#
            let invalidObject = try #require((try? JSONSerialization.jsonObject(with: Data(invalid.utf8))) as? [String: Any], "\(extra)")
            #expect(AcpmuxPaneMethods.breaksParamsRule(invalidObject, modeFields: []), "\(extra)")
        }
    }

    @Test func thePaneMaySendPeerSnapshotWithOnlyTheChatsId() {
        guard case .send = AcpmuxPaneMethods.decide(Self.read(id: 1, params: #"{"sessionId":"huge-blue/lane"}"#),
                                                     isFirst: false, localAppToken: nil) else {
            Issue.record("the relay refused the pane's _acpmux/peer_snapshot")
            return
        }
        func object(_ params: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(Self.read(id: 1, params: params).utf8))) as? [String: Any]
        }
        #expect(!AcpmuxPaneMethods.breaksParamsRule(object(#"{"sessionId":"huge-blue/lane"}"#), modeFields: []))
        // acpmux takes `host`, `limit` and `maxBytes` too; the pane sends none of them.
        for extra in [#""host":"other""#, #""limit":1000"#, #""maxBytes":1"#, #""_meta":{"acpmux":{"peer":"x"}}"#] {
            #expect(AcpmuxPaneMethods.breaksParamsRule(object(#"{"sessionId":"m1",\#(extra)}"#), modeFields: []), "\(extra)")
        }
        #expect(AcpmuxPaneMethods.breaksParamsRule(object(#"["m1"]"#), modeFields: []))
    }

    @Test(.timeLimit(.minutes(1))) func aDownPeersChatIsReadFromTheMacsCopyBeforeItsAttach() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        let reads = { server.peers.first?.frames.filter { $0.contains("_acpmux/peer_snapshot") } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.read(id: 1, params: #"{"sessionId":"m1","host":"other"}"#)])
                == .intentInvalid, "a param the pane never sends")
        #expect(reads().isEmpty, "a refused read reached acpmux: \(reads())")

        // The chat is not in the pane's scope yet: the copy is drawn before its attach.
        #expect(await transport.send(connection: id, frames: [Self.read(id: 2, params: #"{"sessionId":"huge-blue/lane"}"#)]) == nil,
                "the relay refused the pane's _acpmux/peer_snapshot")
        _ = await inbox.frame(containing: #""id":2"#)
        let sent = try #require(reads().first, "the read never reached acpmux")
        let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params as NSDictionary == ["sessionId": "huge-blue/lane"] as NSDictionary)
        #expect(reads().count == 1)
    }
}

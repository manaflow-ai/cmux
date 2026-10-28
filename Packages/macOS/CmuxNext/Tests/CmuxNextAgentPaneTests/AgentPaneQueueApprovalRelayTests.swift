import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The owner's Approve and Decline of a guest's held prompt at the relay boundary (the page's
/// frames into ``AgentPaneTransport``, out to acpmux; acpmux `hub/queue_approve.rs`): both reach
/// acpmux only for a chat in the pane's scope and only in the shapes the pane sends. Approve names
/// the `revision` the owner saw and runs a prompt, so it needs a gesture; Decline needs none.
@Suite(.serialized)
@MainActor
struct AgentPaneQueueApprovalRelayTests {
    static func frame(id: Int, method: String, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
    }

    @Test func approveAndDeclineGoOutInThePanesShapesForTheChatInScope() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let sent = { server.peers.first?.frames.filter { $0.contains("_acpmux/queue_") } ?? [] }
        let approve = "_acpmux/queue_approve"
        let decline = "_acpmux/queue_decline"

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, method: approve, params: #"{"sessionId":"other","promptId":"p","revision":0}"#)]) == .sessionNotInPane)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, method: approve, params: #"{"sessionId":"s","promptId":"p","text":"x"}"#)]) != nil,
                "a param the pane never sends")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, method: decline, params: #"{"sessionId":"s","promptId":"p","revision":1}"#)]) != nil,
                "Decline names no revision")
        #expect(sent().isEmpty, "a refused frame reached acpmux: \(sent())")

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 4, method: approve, params: #"{"sessionId":"s","promptId":"p","revision":2}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":4"#)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 5, method: decline, params: #"{"sessionId":"s","promptId":"q"}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":5"#)
        let frames = sent()
        #expect(frames.count == 2, "\(frames)")
        let params = try frames.map { frame in
            let object = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
            return try #require(object?["params"] as? [String: Any])
        }
        #expect(params.first?["revision"] as? Int == 2)
        #expect(params.last?["promptId"] as? String == "q")
    }

    @Test func aHeldPromptsRecordIsReadForTheChatInScopeOnly() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let get = "_acpmux/queue_get"
        let sent = { server.peers.first?.frames.filter { $0.contains(get) } ?? [] }
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, method: get, params: #"{"sessionId":"other","promptId":"p"}"#)]) == .sessionNotInPane)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, method: get, params: #"{"sessionId":"s","promptId":"p","revision":1}"#)]) != nil,
                "a param the pane never sends")
        #expect(sent().isEmpty, "a refused frame reached acpmux: \(sent())")
        // A read: no gesture.
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, method: get, params: #"{"sessionId":"s","promptId":"p"}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":3"#)
        #expect(sent().count == 1)
        #expect(!AcpmuxPaneMethods.needsGesture(Self.frame(id: 4, method: get, params: #"{"sessionId":"s","promptId":"p"}"#), options: AcpmuxPermissionOptions()))
    }

    @Test func approveNeedsAGestureAndDeclineDoesNot() {
        let options = AcpmuxPermissionOptions()
        #expect(AcpmuxPaneMethods.needsGesture(
            Self.frame(id: 1, method: "_acpmux/queue_approve", params: #"{"sessionId":"s","promptId":"p","revision":0}"#), options: options))
        #expect(!AcpmuxPaneMethods.needsGesture(
            Self.frame(id: 1, method: "_acpmux/queue_decline", params: #"{"sessionId":"s","promptId":"p"}"#), options: options))
    }
}

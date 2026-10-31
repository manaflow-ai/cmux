import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Resuming a paused agent pair at the relay boundary (the page's frames into
/// ``AgentPaneTransport``, out to acpmux; acpmux `hub/agent_pairs.rs`): the pause row's Resume
/// reaches acpmux only for a chat in the pane's scope, with a fresh gesture, and only in the shape
/// the pane sends. `peerSessionId` picks one of that chat's pairs and is not scoped itself: acpmux
/// resumes no pair the named chat is not in.
@Suite(.serialized)
@MainActor
struct AgentPaneAgentPairResumeRelayTests {
    static func frame(id: Int, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/agent_pair_resume","params":\#(params)}"#
    }

    @Test func aResumeGoesOutOnlyForTheChatInScopeWithAGesture() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let sent = { server.peers.first?.frames.filter { $0.contains("_acpmux/agent_pair_resume") } ?? [] }

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, params: #"{"sessionId":"other","peerSessionId":"s"}"#)]) == .sessionNotInPane,
                "a chat outside the pane's scope, even naming one inside it as the peer")
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, params: #"{"sessionId":"s","promptId":"p"}"#)]) != nil,
                "a param the pane never sends")
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, params: #"{"peerSessionId":"other"}"#)]) != nil,
                "no chat named")
        #expect(sent().isEmpty, "a refused frame reached acpmux: \(sent())")

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 4, params: #"{"sessionId":"s","peerSessionId":"other"}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":4"#)
        let frames = sent()
        #expect(frames.count == 1, "\(frames)")
        let object = try JSONSerialization.jsonObject(with: Data(try #require(frames.first).utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "s")
        #expect(params["peerSessionId"] as? String == "other")
    }

    @Test func aResumeNeedsAGesture() {
        let frame = Self.frame(id: 1, params: #"{"sessionId":"s"}"#)
        #expect(AcpmuxPaneMethods.needsGesture(frame, options: AcpmuxPermissionOptions()))
    }
}

import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-ef2m at the relay boundary (the page's frames into ``AgentPaneTransport``, out to acpmux): a
/// side question (`/btw`, `_acpmux/ask`) runs an agent turn, so it goes out like a prompt: only on
/// a fresh gesture, only about a chat in the pane's scope, and with no params the pane never sends.
@Suite(.serialized)
@MainActor
struct AgentPaneSideQuestionRelayTests {
    static func ask(id: Int, session: String, extra: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/ask","params":{"sessionId":"\#(session)","text":"why?"\#(extra)}}"#
    }

    @Test func aSideQuestionGoesOutOnlyOnAGestureForTheChatInTheSameShape() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let asked = { server.peers.first?.frames.filter { $0.contains("_acpmux/ask") } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.ask(id: 1, session: "s")]) == .gestureRequired)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.ask(id: 2, session: "other")]) != nil,
                "a chat outside the pane's scope")
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.ask(id: 3, session: "s", extra: #","cwd":"/"}"#)]) != nil,
                "a param the pane never sends")
        #expect(asked().isEmpty, "a refused question reached acpmux: \(asked())")

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.ask(id: 4, session: "s")]) == nil)
        // The stand-in answers what reached it.
        _ = await inbox.frame(containing: #""id":4"#)
        let sent = try #require(asked().first)
        let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "s")
        #expect(params["text"] as? String == "why?")
        #expect(asked().count == 1)
    }
}

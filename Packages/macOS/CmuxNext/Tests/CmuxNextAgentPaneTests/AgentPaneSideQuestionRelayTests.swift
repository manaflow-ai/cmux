import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The pane relay (the page's frames into ``AgentPaneTransport``, out to acpmux) no longer passes
/// the inline side question `_acpmux/ask`: `/btw` starts a side session (`_acpmux/btw`) instead, and
/// the page stopped sending it. Even with a fresh gesture, for a chat in the pane's scope, it is
/// refused and never reaches acpmux, as the Rust policy (policy.json) refuses it.
@Suite(.serialized)
@MainActor
struct AgentPaneSideQuestionRelayTests {
    static func ask(id: Int, session: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/ask","params":{"sessionId":"\#(session)","text":"why?"}}"#
    }

    @Test func theInlineSideQuestionIsRefusedAndNeverReachesAcpmux() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.ask(id: 1, session: "s")]) == .methodRefused)
        // A later frame that does go out, so the stand-in has seen everything sent before it.
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/status","params":{}}"#]) == nil)
        _ = await inbox.frame(containing: #""id":2"#)
        let asked = server.peers.first?.frames.filter { $0.contains("_acpmux/ask") } ?? []
        #expect(asked.isEmpty, "the inline side question reached acpmux: \(asked)")
    }
}

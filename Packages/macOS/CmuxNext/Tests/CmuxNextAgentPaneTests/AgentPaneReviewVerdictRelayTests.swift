import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Waiting on you's Accept and Request changes send `_acpmux/review_verdict {prUrl, sessionId,
/// verdict, comment}`, and Request changes can send the chat a prompt. History holds no chat, so
/// the verdict follows the source rule (``AcpmuxPaneMethods/sourceScoped``): for a chat outside the
/// pane's scope it takes the click's scope credit, as an attach the person makes. A click already
/// spent attaching chat A cannot also send a verdict to chat B. The Rust copy of this rule is
/// cmux-agent-pane-policy tests/cases/check.json ("a review verdict for a chat outside the scope
/// uses scope credit").
@Suite(.serialized)
@MainActor
struct AgentPaneReviewVerdictRelayTests {
    static func verdict(id: Int, session: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/review_verdict","params":{"prUrl":"https://github.com/o/r/pull/1","sessionId":"\#(session)","verdict":"changes","comment":"fix it"}}"#
    }

    @Test(.timeLimit(.minutes(1))) func aVerdictForAChatOutsideTheScopeNeedsItsOwnClick() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("_acpmux/review_verdict", with: #"{"recorded":true}"#)
        server.answer("_acpmux/attach", with: #"{"session":{"sessionId":"a"}}"#)
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let sent = { server.peers.first?.frames.filter { $0.contains("_acpmux/review_verdict") } ?? [] }

        // No click: neither the pane's own chat nor another one.
        #expect(await transport.send(connection: id, frames: [Self.verdict(id: 1, session: "s")]) == .gestureRequired)
        #expect(await transport.send(connection: id, frames: [Self.verdict(id: 2, session: "b")]) == .gestureRequired)
        #expect(sent().isEmpty, "a refused verdict reached acpmux: \(sent())")

        // The pane's own chat: the click's grant is enough.
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.verdict(id: 3, session: "s")]) == nil,
                "the relay refused a verdict for the pane's own chat")
        _ = await inbox.frame(containing: #""id":3"#)
        #expect(sent().count == 1, "\(sent())")

        // A click spent attaching chat A leaves no scope credit for a verdict to chat B.
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":4,"method":"_acpmux/attach","params":{"sessionId":"a"}}"#]) == nil)
        _ = await inbox.frame(containing: #""id":4"#)
        #expect(await transport.send(connection: id, frames: [Self.verdict(id: 5, session: "b")]) == .gestureRequired,
                "a verdict for another chat went out on a click spent attaching chat A")
        #expect(sent().count == 1, "\(sent())")

        // Its own click brings chat B's verdict in, once.
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.verdict(id: 6, session: "b")]) == nil,
                "the relay refused a verdict the person clicked for")
        _ = await inbox.frame(containing: #""id":6"#)
        #expect(sent().count == 2, "\(sent())")
        #expect(await transport.send(connection: id, frames: [Self.verdict(id: 7, session: "c")]) == .gestureRequired)
        #expect(sent().count == 2, "\(sent())")
    }
}

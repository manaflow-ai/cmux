import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Stopping a running Claude subagent or workflow at the relay boundary (the page's frames into
/// ``AgentPaneTransport``, out to acpmux): the row's stop button (direct.ts stopSubagent) reaches
/// acpmux only for a chat in the pane's scope and only in the shape the pane sends. It stops
/// work and grants nothing, like `_acpmux/kill`, so it needs no gesture.
@Suite(.serialized)
@MainActor
struct AgentPaneSubagentStopRelayTests {
    static func frame(id: Int, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/subagent_stop","params":\#(params)}"#
    }

    @Test func aStopGoesOutOnlyForTheChatInTheShapeThePaneSends() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let sent = { server.peers.first?.frames.filter { $0.contains("_acpmux/subagent_stop") } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, params: #"{"sessionId":"other","subagentSessionId":"a"}"#)]) != nil,
                "a chat outside the pane's scope")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, params: #"{"sessionId":"s","subagentSessionId":"a","command":"ls"}"#)]) != nil,
                "a param the pane never sends")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, params: #"{"subagentSessionId":"a"}"#)]) != nil,
                "no chat named")
        #expect(sent().isEmpty, "a refused frame reached acpmux: \(sent())")

        // No gesture: a stop grants nothing.
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 4, params: #"{"sessionId":"s","subagentSessionId":"a"}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":4"#)
        let frames = sent()
        #expect(frames.count == 1, "\(frames)")
        let object = try JSONSerialization.jsonObject(with: Data(try #require(frames.first).utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "s")
        #expect(params["subagentSessionId"] as? String == "a")
    }
}

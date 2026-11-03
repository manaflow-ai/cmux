import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The MCP connect card and a connected tool's call card at the relay boundary
/// (plans/cmux-next/mcp-connect-DESIGN.md, McpConnectCard.tsx): Connect, Sign in, Save key and Run
/// each go out only on a fresh gesture; an answer only for a chat in the pane's scope; and a key
/// never rides on the connect answer (it goes with `_acpmux/mcp_set_key`).
@Suite(.serialized)
@MainActor
struct AgentPaneMcpRelayTests {
    static func frame(_ id: Int, _ method: String, _ params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
    }

    @Test func everyMcpAnswerNeedsAGestureAndTheChatsScope() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let reached = { (method: String) in server.peers.first?.frames.filter { $0.contains(method) } ?? [] }

        let connect = Self.frame(1, "_acpmux/mcp_connect_answer", #"{"sessionId":"s","requestId":"r1","approve":true,"scope":"chat"}"#)
        #expect(await transport.send(connection: id, frames: [connect]) == .gestureRequired)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(2, "_acpmux/mcp_connect_answer",
            #"{"sessionId":"other","requestId":"r1","approve":true,"scope":"chat"}"#)]) != nil, "a chat outside the pane's scope")
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(3, "_acpmux/mcp_connect_answer",
            #"{"sessionId":"s","requestId":"r1","approve":true,"scope":"chat","key":"k-1"}"#)]) != nil,
            "a key never rides on the connect answer")
        #expect(reached("_acpmux/mcp_connect_answer").isEmpty)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(4, "_acpmux/mcp_connect_answer",
            #"{"sessionId":"s","requestId":"r1","approve":true,"scope":"chat"}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":4"#)
        #expect(reached("_acpmux/mcp_connect_answer").count == 1)

        for (n, method, params) in [
            (5, "_acpmux/mcp_sign_in", #"{"id":"mcp_0123456789abcdef"}"#),
            (6, "_acpmux/mcp_set_key", #"{"id":"mcp_0123456789abcdef","key":"k-1"}"#),
            (7, "_acpmux/mcp_call_answer", #"{"sessionId":"s","requestId":"c1","approve":true,"always":false}"#),
        ] {
            #expect(await transport.send(connection: id, frames: [Self.frame(n, method, params)]) == .gestureRequired, "\(method)")
            transport.gestures.record()
            #expect(await transport.send(connection: id, frames: [Self.frame(n + 10, method, params)]) == nil, "\(method)")
            _ = await inbox.frame(containing: #""id":\#(n + 10)"#)
            #expect(reached(method).count == 1, "\(method)")
        }
    }
}

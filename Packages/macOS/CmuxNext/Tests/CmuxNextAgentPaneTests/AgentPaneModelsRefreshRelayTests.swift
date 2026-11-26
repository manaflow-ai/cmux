import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-ncc.48 at the relay boundary (the page's frames into ``AgentPaneTransport``, out to acpmux):
/// the model picker's Refresh models sends `_acpmux/models {refresh: true}`, which makes acpmux
/// probe its agents' model lists again. It grants nothing, so it needs no gesture, and it carries
/// no other param.
@Suite(.serialized)
@MainActor
struct AgentPaneModelsRefreshRelayTests {
    static func models(id: Int, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/models","params":\#(params)}"#
    }

    @Test func refreshModelsReachesAcpmuxAndNoOtherParamDoes() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        let sent = { server.peers.first?.frames.filter { $0.contains("_acpmux/models") } ?? [] }

        // cmux#49717: a param the pane never sends is dropped, not refused; the read goes without it.
        #expect(await transport.send(connection: id, frames: [Self.models(id: 1, params: #"{"refresh":true,"cwd":"/"}"#)]) == nil,
                "the relay refused a read with a param the pane never sends")
        _ = await inbox.frame(containing: #""id":1"#)
        let stripped = try #require(sent().first, "the stripped read never reached acpmux")
        let strippedObject = try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any]
        #expect(strippedObject?["params"] as? NSDictionary == ["refresh": true] as NSDictionary, "cwd reached acpmux: \(stripped)")

        #expect(await transport.send(connection: id, frames: [Self.models(id: 2, params: #"{"refresh":true}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":2"#)
        let frame = try #require(sent().dropFirst().first)
        let object = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params["refresh"] as? Bool == true)
        #expect(sent().count == 2)
    }
}

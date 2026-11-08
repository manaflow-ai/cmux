import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The New Tab's New project at the relay boundary (the page's frames into ``AgentPaneTransport``,
/// out to acpmux): `_acpmux/project_new` makes a folder and trusts it, so it goes out only with a
/// fresh gesture (the Send that starts its chat) and only as `{name}`.
@Suite(.serialized)
@MainActor
struct AgentPaneProjectNewRelayTests {
    static func frame(id: Int, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/project_new","params":\#(params)}"#
    }

    @Test func aNewProjectGoesOutOnlyWithAGestureAndOnlyItsName() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        let sent = { server.peers.first?.frames.filter { $0.contains("_acpmux/project_new") } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, params: #"{"name":"habit-tracker"}"#)]) != nil,
                "no gesture")
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, params: #"{"name":"x","root":"/etc"}"#)]) != nil,
                "a param the pane never sends")
        #expect(sent().isEmpty, "a refused frame reached acpmux: \(sent())")

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, params: #"{"name":"habit-tracker"}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":3"#)
        let frames = sent()
        #expect(frames.count == 1, "\(frames)")
        let object = try JSONSerialization.jsonObject(with: Data(try #require(frames.first).utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params["name"] as? String == "habit-tracker")
        #expect(params.count == 1)
    }

    @Test func aNewProjectNeedsAGesture() {
        let frame = Self.frame(id: 1, params: #"{"name":"a"}"#)
        #expect(AcpmuxPaneMethods.needsGesture(frame, options: AcpmuxPermissionOptions()))
    }
}

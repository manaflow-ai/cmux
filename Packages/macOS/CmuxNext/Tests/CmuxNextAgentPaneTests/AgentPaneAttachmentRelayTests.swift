import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo, 2026-10-13 (a sent prompt's images vanished), at the relay boundary (the page's frames into
/// ``AgentPaneTransport``, out to acpmux): the pane reads a sent prompt's image back with
/// `_acpmux/attachment`, a read like `_acpmux/events` that acpmux answers only for an image the
/// chat's own log names. It goes out with the chat and the image's id, and nothing else.
@Suite(.serialized)
@MainActor
struct AgentPaneAttachmentRelayTests {
    static func read(id: Int, extra: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/attachment","params":{"sessionId":"s","id":"ab12"\#(extra)}}"#
    }

    @Test func aSentPromptsImageIsReadBackWithOnlyTheChatAndItsId() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        let reads = { server.peers.first?.frames.filter { $0.contains("_acpmux/attachment") } ?? [] }

        // cmux#49717: a param the pane never sends is dropped, not refused; the read goes without it.
        #expect(await transport.send(connection: id, frames: [Self.read(id: 1, extra: #","path":"/etc/hosts""#)]) == nil,
                "the relay refused a read with a param the pane never sends")
        _ = await inbox.frame(containing: #""id":1"#)
        let stripped = try #require(reads().first, "the stripped read never reached acpmux")
        let strippedObject = try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any]
        #expect(strippedObject?["params"] as? NSDictionary == ["sessionId": "s", "id": "ab12"] as NSDictionary,
                "path reached acpmux: \(stripped)")

        #expect(await transport.send(connection: id, frames: [Self.read(id: 2)]) == nil)
        _ = await inbox.frame(containing: #""id":2"#)
        let sent = try #require(reads().dropFirst().first)
        let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "s")
        #expect(params["id"] as? String == "ab12")
        #expect(reads().count == 2)
    }
}

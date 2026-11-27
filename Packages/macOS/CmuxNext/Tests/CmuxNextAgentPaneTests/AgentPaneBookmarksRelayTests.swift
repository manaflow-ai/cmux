import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Prompt bookmarks at the relay boundary (the page's frames into ``AgentPaneTransport``, out to
/// acpmux): the thread minimap reads and toggles the marks of the chat it shows. Both methods
/// reach acpmux only for a chat in the pane's scope and only in the shape the pane sends; they
/// grant nothing, so they need no gesture.
@Suite(.serialized)
@MainActor
struct AgentPaneBookmarksRelayTests {
    static func frame(id: Int, method: String, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
    }

    @Test func bookmarksGoOutOnlyForTheChatInTheShapeThePaneSends() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let sent = { server.peers.first?.frames.filter { $0.contains("_acpmux/bookmark_") } ?? [] }
        let set = "_acpmux/bookmark_set", get = "_acpmux/bookmark_get"

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, method: set, params: #"{"sessionId":"other","seq":3,"bookmarked":true}"#)]) != nil,
                "a chat outside the pane's scope")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, method: get, params: #"{"sessionId":"other"}"#)]) != nil,
                "a chat outside the pane's scope")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, method: set, params: #"{"sessionId":"s","seq":3,"bookmarked":true,"command":"ls"}"#)]) != nil,
                "a param the pane never sends")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 4, method: get, params: #"{"sessionId":"s","cwd":"/"}"#)]) != nil,
                "a param the pane never sends")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 5, method: set, params: #"{"seq":3,"bookmarked":true}"#)]) != nil,
                "no chat named")
        #expect(sent().isEmpty, "a refused frame reached acpmux: \(sent())")

        // No gesture: a mark grants nothing.
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 6, method: set, params: #"{"sessionId":"s","seq":3,"bookmarked":true}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":6"#)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 7, method: get, params: #"{"sessionId":"s"}"#)]) == nil)
        _ = await inbox.frame(containing: #""id":7"#)
        let frames = sent()
        #expect(frames.count == 2, "\(frames)")
        let object = try JSONSerialization.jsonObject(with: Data(try #require(frames.first).utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "s")
        #expect(params["seq"] as? Int == 3)
        #expect(params["bookmarked"] as? Bool == true)
    }
}

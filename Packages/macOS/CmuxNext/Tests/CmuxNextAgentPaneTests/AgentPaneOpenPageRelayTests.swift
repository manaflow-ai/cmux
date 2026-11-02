import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The chat's opening page and its older pages at the relay boundary (the page's frames into
/// ``AgentPaneTransport``, out to acpmux): the pane caps both by `maxBytes` (#20536, cx-2lv1k), so
/// `_acpmux/attach` and `_acpmux/events` carry it. A refused attach leaves the chat unbound: its tab
/// stays blank and it never shows its transcript.
@Suite(.serialized)
@MainActor
struct AgentPaneOpenPageRelayTests {
    static func request(id: Int, method: String, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
    }

    @Test(.timeLimit(.minutes(1))) func aChatsOpeningAndOlderPagesReachAcpmuxWithTheirByteCap() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let sent = { (method: String) in server.peers.first?.frames.filter { $0.contains(method) } ?? [] }

        // As webviews direct.ts attach(): opening a chat.
        let attach = Self.request(id: 1, method: "_acpmux/attach", params: """
            {"sessionId":"s","limit":400,"maxBytes":131072,"kinds":["transcript"],"eventStream":true,"visible":true}
            """)
        try #require(await transport.send(connection: id, frames: [attach]) == nil, "the pane refused a chat's opening page")
        _ = await inbox.frame(containing: #""id":1"#)
        let opened = try #require(sent("_acpmux/attach").first, "the opening page never reached acpmux")
        let openParams = try #require((try JSONSerialization.jsonObject(with: Data(opened.utf8)) as? [String: Any])?["params"] as? [String: Any])
        #expect(openParams["maxBytes"] as? Int == 131072)

        // As webviews direct.ts fetchOlder(): an older page as the reader scrolls up.
        let older = Self.request(id: 2, method: "_acpmux/events", params: """
            {"sessionId":"s","beforeSeq":500,"limit":400,"maxBytes":262144,"kinds":["transcript"]}
            """)
        try #require(await transport.send(connection: id, frames: [older]) == nil, "the pane refused an older page")
        _ = await inbox.frame(containing: #""id":2"#)
        #expect(sent("_acpmux/events").count == 1, "the older page never reached acpmux")

        let native = Self.request(id: 3, method: "_acpmux/native_history", params: """
            {"sessionId":"s","before":4096,"mark":"transcript-boundary-mark"}
            """)
        try #require(await transport.send(connection: id, frames: [native]) == nil)
        _ = await inbox.frame(containing: #""id":3"#)
        let nativeFrame = try #require(sent("_acpmux/native_history").first)
        let nativeParams = try #require((try JSONSerialization.jsonObject(with: Data(nativeFrame.utf8)) as? [String: Any])?["params"] as? [String: Any])
        #expect(nativeParams["mark"] as? String == "transcript-boundary-mark")
    }
}

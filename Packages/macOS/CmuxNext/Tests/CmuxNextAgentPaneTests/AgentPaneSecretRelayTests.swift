import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-ncc.42 at the relay boundary (the page's frames into ``AgentPaneTransport``, out to acpmux):
/// the pane's private secret card answers an agent's `request_secret` with `_acpmux/secret_submit`.
/// The answer goes out only on a fresh gesture, only for a chat in the pane's scope, and with no
/// param the card never sends. The app's acpmux offers the tools (`ACPMUX_SECRET_TOOLS`).
@Suite(.serialized)
@MainActor
struct AgentPaneSecretRelayTests {
    static func answer(id: Int, session: String, extra: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/secret_submit","params":{"sessionId":"\#(session)","secretId":"c1","value":"sk-test"\#(extra)}}"#
    }

    @Test func theCardsAnswerGoesOutOnlyOnAGestureForTheChatInTheSameShape() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let answered = { server.peers.first?.frames.filter { $0.contains("_acpmux/secret_submit") } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.answer(id: 1, session: "s")]) == .gestureRequired)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.answer(id: 2, session: "other")]) != nil,
                "a chat outside the pane's scope")
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.answer(id: 3, session: "s", extra: #","env":"PATH"}"#)]) != nil,
                "a param the card never sends")
        #expect(answered().isEmpty, "a refused answer reached acpmux: \(answered())")

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.answer(id: 4, session: "s")]) == nil)
        _ = await inbox.frame(containing: #""id":4"#)
        let sent = try #require(answered().first)
        let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "s")
        #expect(params["secretId"] as? String == "c1")
        #expect(params["value"] as? String == "sk-test")
        #expect(answered().count == 1)
    }

    @Test func theAppsAcpmuxOffersTheSecretTools() throws {
        let environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: nil, environment: ["PATH": "/bin"],
            userHome: URL(fileURLWithPath: "/tmp", isDirectory: true), uid: 501, isExecutable: { _ in true },
            executableOverride: nil))
        #expect(environment.childEnvironment["ACPMUX_SECRET_TOOLS"] == "1")
    }
}

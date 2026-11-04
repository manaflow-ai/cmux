import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Agent setup (``AgentSetupPane``): `chat.setupPane` opens only the pane's own chat in a tab of its
/// own, and the setup screen's frames reach acpmux only for the chat in the pane's scope, with the
/// params the page sends; Save (`_acpmux/agent_setup/save`) only on the person's click.
@Suite(.serialized)
@MainActor
struct AgentSetupPaneTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    static func read(id: Int, session: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/agent_setup","params":{"sessionId":"\#(session)"}}"#
    }

    static func save(id: Int, session: String, extra: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/agent_setup/save","params":{"sessionId":"\#(session)","systemPrompt":"Be brief."\#(extra)}}"#
    }

    @Test func decodesTheMethod() {
        let request = AgentPaneRequest(body: ["method": "chat.setupPane", "params": ["sessionId": "chat-1"]])
        #expect(request == .setupPane("chat-1"))
        #expect(AgentPageOps.methods["chat.setupPane"] == "chat.setupPane")
        #expect(String(describing: request) == "setupPane")
        for params: [String: Any] in [[:], ["sessionId": ""], ["sessionId": 3], ["sessionId": String(repeating: "a", count: 257)]] {
            if case .setupPane = AgentPaneRequest(body: ["method": "chat.setupPane", "params": params]) { Issue.record("taken: \(params)") }
        }
        #expect(AgentSetupPane.reveal == "agent-setup")
    }

    @Test func opensOnlyThePanesOwnChat() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-1")
        var opened: [String] = []
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            openSetup: { opened.append($0); return true })
        let other = await model.respond(to: .setupPane("chat-2"))
        #expect(other["ok"] as? Bool == false, "another chat's setup opened: \(other)")
        #expect(opened.isEmpty)
        let own = await model.respond(to: .setupPane("chat-1"))
        #expect((own["value"] as? [String: Any])?["opened"] as? Bool == true, "\(own)")
        #expect(opened == ["chat-1"])
    }

    @Test func theSetupFramesGoOutOnlyForTheChatInScopeAndSaveOnlyOnAClick() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("_acpmux/agent_setup", with: #"{"systemPrompt":null}"#)
        server.answer("_acpmux/agent_setup/save", with: #"{"saved":true}"#)
        let transport = AgentPaneTransport()
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let saves = { server.peers.first?.frames.filter { $0.contains("_acpmux/agent_setup/save") } ?? [] }

        // A read of the pane's chat needs no click; another chat's is refused.
        #expect(await transport.send(connection: id, frames: [Self.read(id: 1, session: "s")]) == nil)
        #expect(await transport.send(connection: id, frames: [Self.read(id: 2, session: "other")]) != nil)

        // Save: never without the person's click, never for a chat out of scope, never with a param the page never sends.
        #expect(await transport.send(connection: id, frames: [Self.save(id: 3, session: "s")]) == .gestureRequired)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.save(id: 4, session: "other")]) != nil, "a chat the pane does not show")
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.save(id: 5, session: "s", extra: #","harness":"claude""#)]) != nil)
        #expect(saves().isEmpty, "a refused save reached acpmux: \(saves())")

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.save(id: 6, session: "s")]) == nil)
        _ = await inbox.frame(containing: #""id":6"#)
        #expect(saves().count == 1)
    }
}

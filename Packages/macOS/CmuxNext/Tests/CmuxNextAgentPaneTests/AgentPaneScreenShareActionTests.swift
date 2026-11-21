import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneScreenShareActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func screenSharingRequiresAGestureAndTheSameChat() async {
        let model = AgentPaneModel(host: NoHost())
        var shown = "chat-a"
        var calls: [[String: String]] = []
        model.onRunAction = { id, arguments in
            #expect(id == "session.screenShare")
            calls.append(arguments)
            return .ran
        }
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, showsChat: { $0 == shown })
        #expect(await model.respond(to: .runAction("session.screenShare", session: "chat-a"))["ok"] as? Bool != true)
        #expect(calls.isEmpty)
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("session.screenShare", session: "chat-a"))["ok"] as? Bool == true)
        #expect(calls == [["session": "chat-a"]], "the page supplies no machine or device target")
        shown = "chat-b"
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("session.screenShare", session: "chat-a"))["ok"] as? Bool != true)
        #expect(calls.count == 1)
    }
}

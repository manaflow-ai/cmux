import Testing
@testable import CmuxNextAgentPane

/// A chat's own "…" offers Switch to terminal on half of a terminal and chat pair (user 2026-11-20: bring back the
/// terminal/chat switch "inside the 3 dots thing"). The page runs the app's Toggle Terminal and Chat
/// (`palette.toggleTerminalChat`) on its own tab, on the person's fresh gesture in the pane, bound to the chat
/// whose menu offered it.
@MainActor
struct AgentPaneTerminalSwitchActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    static let toggle = "palette.toggleTerminalChat"

    @Test func theChatsMenuRunsToggleTerminalAndChatOnAGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        model.onRunAction = { id, _ in ran.append(id); return .ran }
        #expect(await model.respond(to: .runAction(Self.toggle))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no switch: page script cannot move the person's view")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction(Self.toggle))["ok"] as? Bool == true)
        #expect(ran == [Self.toggle])
    }
}

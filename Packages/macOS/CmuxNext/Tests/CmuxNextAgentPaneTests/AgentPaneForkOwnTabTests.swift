import Testing
@testable import CmuxNextAgentPane

/// Leo 2026-10-13 (cosmic-gray): a new chat made from this one (a fork, a Continue in…) took over
/// the chat's tab, so the chat itself left the sidebar. The page asks the host to open the new
/// chat in a tab of its own (`chat.openTab`): the chat keeps its tab and its session.
@Suite
@MainActor
struct AgentPaneForkOwnTabTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func pane(opened: @escaping (String) -> Void) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat")
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, openTab: opened)
        return model
    }

    private static func openTab(_ session: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "chat.openTab", "params": ["sessionId": session]])
    }

    @Test func aForkOpensInItsOwnTabAndTheChatKeepsItsSession() async {
        var opened: [String] = []
        let model = Self.pane { opened.append($0) }
        // The fork's reply put it in the pane's scope (AcpmuxPaneSessions).
        model.transport.sessions.add("fork")
        let reply = await model.respond(to: Self.openTab("fork"))
        #expect(reply["ok"] as? Bool == true)
        #expect(opened == ["fork"])
        #expect(model.sessionId == "chat", "the fork took over the chat's tab")
    }

    @Test func onlyASessionThisPaneMadeOpensAndNeverTheChatItself() async {
        var opened: [String] = []
        let model = Self.pane { opened.append($0) }
        _ = await model.respond(to: Self.openTab("someone-elses"))
        _ = await model.respond(to: Self.openTab("chat"))
        #expect(opened.isEmpty)
    }
}

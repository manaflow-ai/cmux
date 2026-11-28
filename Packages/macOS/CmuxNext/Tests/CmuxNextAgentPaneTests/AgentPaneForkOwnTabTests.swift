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

    /// The sessions the host opened a tab on.
    @MainActor private final class Opened { var ids: [String] = [] }

    private static func pane(opens: Bool = true, opened: Opened = Opened()) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat")
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, openTab: {
            opened.ids.append($0)
            return opens
        })
        return model
    }

    private static func openTab(_ session: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "chat.openTab", "params": ["sessionId": session]])
    }

    @Test func aForkOpensInItsOwnTabAndTheChatKeepsItsSession() async {
        let opened = Opened()
        let model = Self.pane(opened: opened)
        // The fork's reply put it in the pane's scope (AcpmuxPaneSessions).
        model.transport.sessions.add("fork")
        let reply = await model.respond(to: Self.openTab("fork"))
        #expect(reply["ok"] as? Bool == true)
        #expect(opened.ids == ["fork"])
        #expect(model.sessionId == "chat", "the fork took over the chat's tab")
    }

    @Test func onlyASessionThisPaneMadeOpensAndNeverTheChatItself() async {
        let opened = Opened()
        let model = Self.pane(opened: opened)
        _ = await model.respond(to: Self.openTab("someone-elses"))
        _ = await model.respond(to: Self.openTab("chat"))
        #expect(opened.ids.isEmpty)
    }

    /// A host that opens no tab (a pane of another machine, no daemon) says so, so the page opens
    /// the new chat in the chat's tab instead of losing it.
    @Test func aTabTheHostCouldNotOpenIsARefusal() async {
        let model = Self.pane(opens: false)
        model.transport.sessions.add("fork")
        let reply = await model.respond(to: Self.openTab("fork"))
        #expect(reply["ok"] as? Bool == false)
    }
}

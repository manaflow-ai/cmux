import Testing
@testable import CmuxNextAgentPane

/// Leo 2026-10-13 (cosmic-gray): a new chat made from this one (a fork, a Continue In…) took over
/// the chat's tab, so the chat itself left the sidebar. The page asks the host to open the new
/// chat in a tab of its own (`chat.openTab`): the chat keeps its tab and its session.
@Suite
@MainActor
struct AgentPaneForkOwnTabTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The sessions the host opened a tab on.
    @MainActor private final class Opened {
        var ids: [String] = []
        var destinations: [AgentForkDestination] = []
    }

    private static func pane(opens: Bool = true, opened: Opened = Opened()) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat")
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, openTab: { id, destination in
            opened.ids.append(id)
            opened.destinations.append(destination)
            return opens
        })
        return model
    }

    private static func openTab(_ session: String, placement: String? = nil) -> AgentPaneRequest {
        var params: [String: Any] = ["sessionId": session]
        if let placement { params["placement"] = placement }
        return AgentPaneRequest(body: ["method": "chat.openTab", "params": params])
    }

    /// The palette's Fork Conversation step and the chat's right-click Fork name a destination
    /// (`placement`); the host opens the fork there. No placement (the chat page's own Fork, an
    /// older page) uses the default destination; an unknown one uses the same default.
    @Test(arguments: [
        ("right", AgentForkDestination.right), ("left", .left), ("up", .up), ("down", .down),
        ("tab", .tab), ("workspace", .workspace), ("window", .window),
    ])
    func aForkOpensAtTheDestinationThePageNames(placement: String, destination: AgentForkDestination) async {
        let opened = Opened()
        let model = Self.pane(opened: opened)
        model.transport.sessions.add("fork")
        let reply = await model.respond(to: Self.openTab("fork", placement: placement))
        #expect(reply["ok"] as? Bool == true)
        #expect(opened.destinations == [destination])
    }

    @Test(arguments: [nil, "sideways"] as [String?])
    func aForkWithoutAPlacementUsesTheSharedDefault(placement: String?) async {
        let opened = Opened()
        let model = Self.pane(opened: opened)
        model.transport.sessions.add("fork")
        _ = await model.respond(to: Self.openTab("fork", placement: placement))
        #expect(opened.destinations == [.default])
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

import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The "..." menu's New side chat: the page forks the chat (its own `acp.session.fork`), then
/// `chat.sideChat` tags the fork `side` with the chat's session and opens it in a split beside
/// the chat. Only a fork this pane made, never the chat itself.
@MainActor
@Suite struct AgentPaneSideChatTests {
    private static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "chat.sideChat", "params": params] as [String: Any])
    }

    @Test func theRequestCarriesTheFork() {
        #expect(Self.request(["sessionId": "f1"]) == .sideChat("f1"))
        #expect(Self.request([:]) == .unsupported("chat.sideChat"))
        #expect(AgentPageOps.method(for: "cmux.agent.chat.sideChat") == "chat.sideChat")
    }

    @Test func theForkIsTaggedWithItsChatAndOpensBesideIt() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), sessionId: "s1")
        model.transport.sessions.add("f1")
        var tagged: [String] = []
        var opened: [String] = []
        model.transport.tagSession = { session, set, remove in
            tagged.append("\(session) \(set) \(remove)")
        }
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { [:] }, openSide: { opened.append($0) })
        let reply = await model.respond(to: .sideChat("f1"))
        #expect(reply["ok"] as? Bool == true)
        #expect(tagged == ["f1 [\"side\": \"s1\"] []"])
        #expect(opened == ["f1"])
    }

    @Test func aSessionThePaneDidNotMakeIsRefused() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), sessionId: "s1")
        var opened: [String] = []
        model.transport.tagSession = { _, _, _ in }
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { [:] }, openSide: { opened.append($0) })
        #expect(await model.respond(to: .sideChat("other"))["ok"] as? Bool == false)
        #expect(await model.respond(to: .sideChat("s1"))["ok"] as? Bool == false)
        #expect(opened.isEmpty)
    }
}

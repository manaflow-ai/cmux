import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The "..." menu's Archive: `chat.archive` tags the pane's own session `archived` in acpmux
/// (Unarchive removes the tag), and archiving closes the chat's tab.
@MainActor
@Suite struct AgentPaneArchiveTests {
    private static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "chat.archive", "params": params] as [String: Any])
    }

    @Test func theRequestCarriesWhichWay() {
        #expect(Self.request(["archived": true]) == .archive(true))
        #expect(Self.request(["archived": false]) == .archive(false))
        #expect(Self.request([:]) == .unsupported("chat.archive"))
        #expect(AgentPageOps.method(for: "cmux.agent.chat.archive") == "chat.archive")
    }

    @Test func archivingTagsThePanesSessionAndClosesItsTab() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), sessionId: "s1")
        var tagged: [String] = []
        var ran: [String] = []
        model.transport.tagSession = { session, set, remove in
            tagged.append("\(session) set=\(set.keys.sorted()) remove=\(remove)")
        }
        model.header = AgentPaneHeaderHooks(run: { id, _ in ran.append(id) }, tabState: { [:] })
        var reply = await model.respond(to: .archive(true))
        #expect(reply["ok"] as? Bool == true)
        reply = await model.respond(to: .archive(false))
        #expect(reply["ok"] as? Bool == true)
        #expect(tagged == ["s1 set=[\"archived\"] remove=[]", "s1 set=[] remove=[\"archived\"]"])
        #expect(ran == ["closeTab"])
    }

    @Test func aChatWithoutASessionOrAFailedTagKeepsItsTab() async {
        var ran: [String] = []
        let fresh = AgentPaneModel(host: MockAgentPaneHost())
        fresh.header = AgentPaneHeaderHooks(run: { id, _ in ran.append(id) }, tabState: { [:] })
        #expect(await fresh.respond(to: .archive(true))["ok"] as? Bool == false)

        let model = AgentPaneModel(host: MockAgentPaneHost(), sessionId: "s1")
        model.transport.tagSession = { _, _, _ in throw AcpmuxStatusClient.Failure.closed }
        model.header = AgentPaneHeaderHooks(run: { id, _ in ran.append(id) }, tabState: { [:] })
        #expect(await model.respond(to: .archive(true))["ok"] as? Bool == false)
        #expect(ran.isEmpty)
    }
}

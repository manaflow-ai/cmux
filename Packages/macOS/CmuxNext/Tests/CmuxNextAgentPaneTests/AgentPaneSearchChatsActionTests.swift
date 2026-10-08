import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Decision K1: the pane's "Show all" chats opens the command palette's chats page through the
/// app action `agentPane.searchChats` (`action.run`), not a sheet of its own.
@MainActor
@Suite struct AgentPaneSearchChatsActionTests {
    @Test func showAllRunsTheSearchChatsAppAction() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var ran: [String] = []
        model.onRunAction = { ran.append($0); return true }
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "action.run", "params": ["id": "agentPane.searchChats"]] as [String: Any]))
        #expect(reply["error"] == nil)
        #expect(ran == ["agentPane.searchChats"])
        // Other actions stay refused.
        let refused = await model.respond(to: .runAction("closeWindow"))
        #expect(refused["error"] != nil)
        #expect(ran == ["agentPane.searchChats"])
    }
}

import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneComposerActionsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
            throw AgentPaneHostError.daemonStopped
        }
    }

    @Test func readOnlyCatalogRowsReachThePageWithoutAUserGesture() async {
        #expect(AgentPageOps.methods["action.composerList"] == "action.composerList")
        let request = AgentPaneRequest(body: ["method": "action.composerList"])
        #expect(request == .listComposerActions)

        let model = AgentPaneModel(host: NoHost())
        model.onListComposerActions = {
            [["id": "openBrowser", "section": "tools", "name": "New Browser Tab",
              "description": "Open a browser tab", "icon": "globe"]]
        }
        let reply = await model.respond(to: request)
        #expect(reply["ok"] as? Bool == true)
        let value = reply["value"] as? [String: Any]
        let rows = value?["actions"] as? [[String: String]]
        #expect(rows?.first?["id"] == "openBrowser")
    }
}

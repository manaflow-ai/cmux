import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `agentPane.showContextUsage` reaches the page as the `composer` event, and the page's Hide or
/// Show Context Usage (`pane.showContextUsage`) asks the host to write it.
@MainActor
@Suite struct AgentPaneComposerTests {
    @Test func theEventCarriesTheSetting() {
        var setting = AgentPaneComposerSetting()
        setting.showContextUsage = false
        let event = AgentPageEvent.composer(setting)
        #expect(event.kind == "composer")
        #expect(event.value == ["showContextUsage": false])
    }

    @Test func thePagesHideAndShowReachTheHost() async {
        #expect(AgentPaneRequest(body: ["method": "pane.showContextUsage", "params": ["show": false]]) == .showContextUsage(false))
        #expect(AgentPaneRequest(body: ["method": "pane.showContextUsage", "params": ["show": "no"]]) == .unsupported("pane.showContextUsage"))
        #expect(AgentPageOps.methods["pane.showContextUsage"] == "pane.showContextUsage")
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var written: [Bool] = []
        model.onShowContextUsage = { written.append($0) }
        let reply = await model.respond(to: .showContextUsage(false))
        #expect(reply["ok"] as? Bool == true)
        #expect(written == [false])
    }
}

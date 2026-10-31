import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneSendScrollRequestTests {
    @Test(arguments: [true, false])
    func theComposerWritesOnlyTheSendScrollKey(_ show: Bool) {
        let request = AgentPaneRequest(body: ["method": "pane.setScrollToBottomOnSend", "params": ["show": show]])
        #expect(request == .composerSetting(path: ["agentPane", "scrollToBottomOnSend"], show: show))
    }

    @Test func malformedValuesAreRefused() {
        for params: [String: Any] in [["show": "false"], ["show": NSNull()], [:]] {
            let request = AgentPaneRequest(body: ["method": "pane.setScrollToBottomOnSend", "params": params])
            #expect(request == .unsupported("pane.setScrollToBottomOnSend"))
        }
    }

    @Test func thePageCanCallIt() {
        #expect(AgentPageOps.methods["pane.setScrollToBottomOnSend"] == "pane.setScrollToBottomOnSend")
    }
}

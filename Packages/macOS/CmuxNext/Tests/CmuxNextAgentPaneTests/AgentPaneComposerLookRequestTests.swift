import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `pane.setComposerLook {look}` (the chat's look dots while `agentPane.composerLook` pins a look):
/// the host writes `agentPane.composerLook` and ignores anything but its three values.
struct AgentPaneComposerLookRequestTests {
    @Test(arguments: ["auto", "codex", "claude"])
    func eachLookWritesTheKey(_ look: String) {
        let request = AgentPaneRequest(body: ["method": "pane.setComposerLook", "params": ["look": look]])
        #expect(request == .displaySetting(path: ["agentPane", "composerLook"], value: .string(look)))
    }

    @Test func anythingElseIsRefused() {
        for params: [String: Any] in [["look": "Codex"], ["look": "t3"], ["look": true], ["look": NSNull()], [:]] {
            let request = AgentPaneRequest(body: ["method": "pane.setComposerLook", "params": params])
            #expect(request == .unsupported("pane.setComposerLook"))
        }
    }

    @Test func thePageCanCallIt() {
        #expect(AgentPageOps.methods["pane.setComposerLook"] == "pane.setComposerLook")
    }
}

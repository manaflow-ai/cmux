import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `pane.setComposerRing {ring}` (the composer ring's Context or Plan Usage choice): the host writes
/// `agentPane.composerRing` and ignores anything but the two rings.
struct AgentPaneComposerRingRequestTests {
    @Test(arguments: ["context", "planUsage"])
    func eachRingWritesTheKey(_ ring: String) {
        let request = AgentPaneRequest(body: ["method": "pane.setComposerRing", "params": ["ring": ring]])
        #expect(request == .displaySetting(path: ["agentPane", "composerRing"], value: .string(ring)))
    }

    @Test func anythingElseIsRefused() {
        for params: [String: Any] in [["ring": "plan"], ["ring": "Context"], ["ring": "PlanUsage"], ["ring": true], ["ring": NSNull()], [:]] {
            let request = AgentPaneRequest(body: ["method": "pane.setComposerRing", "params": params])
            #expect(request == .unsupported("pane.setComposerRing"))
        }
    }

    @Test func thePageCanCallIt() {
        #expect(AgentPageOps.methods["pane.setComposerRing"] == "pane.setComposerRing")
    }
}

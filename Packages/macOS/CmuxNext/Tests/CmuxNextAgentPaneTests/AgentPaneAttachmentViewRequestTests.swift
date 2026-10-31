import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `pane.setAttachmentView {view}` (the composer's Inline or Strip choice): the host writes
/// `agentPane.attachmentView` and refuses anything but the two views.
struct AgentPaneAttachmentViewRequestTests {
    @Test(arguments: ["inline", "strip"])
    func eachViewWritesTheKey(_ view: String) {
        let request = AgentPaneRequest(body: ["method": "pane.setAttachmentView", "params": ["view": view]])
        #expect(request == .displaySetting(path: ["agentPane", "attachmentView"], value: .string(view)))
    }

    @Test func anythingElseIsRefused() {
        for params: [String: Any] in [["view": "row"], ["view": "Strip"], ["view": true], ["view": NSNull()], [:]] {
            let request = AgentPaneRequest(body: ["method": "pane.setAttachmentView", "params": params])
            #expect(request == .unsupported("pane.setAttachmentView"))
        }
    }

    @Test func thePageCanCallIt() {
        #expect(AgentPageOps.methods["pane.setAttachmentView"] == "pane.setAttachmentView")
    }
}

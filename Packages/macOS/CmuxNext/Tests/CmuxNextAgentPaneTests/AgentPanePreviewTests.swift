import Testing
@testable import CmuxNextAgentPane

/// Preview features (`labs.previewFeatures`) reach the page as one flag.
@MainActor
@Suite struct AgentPanePreviewTests {
    @Test func thePageHearsTheFlag() {
        #expect(AgentPaneView.previewScript(true) == "window.cmuxAcpmuxBridge?.applyPreview?.(true);")
        #expect(AgentPaneView.previewScript(false) == "window.cmuxAcpmuxBridge?.applyPreview?.(false);")
    }
}

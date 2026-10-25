import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// The chat header's Browser opening the chat's page, behind Debug Settings
/// `agentChat.browserOpensPreview` (on by default, Leo 2026-10-20): the page learns the toggle from
/// the header state, so with it off the header shows Preview beside a plain Browser again.
@Suite(.serialized)
@MainActor
struct AgentPaneBrowserOpensPreviewHeaderTests {
    private func with(_ value: Bool?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        TunableStore.shared.set(AgentPaneTunables.browserOpensPreview.key, value.map(TunableValue.bool))
        defer { TunableStore.shared.set(AgentPaneTunables.browserOpensPreview.key, nil) }
        try body()
    }

    @Test func onByDefaultThePageIsToldBrowserOpensThePage() {
        with(nil) {
            #expect(AgentPaneTunables.browserOpensPreview.value == true)
            #expect(AgentPaneHeaderState().json.objectValue?["browserOpensPreview"] == .bool(true))
        }
    }

    @Test func offThePageIsToldToKeepPreviewSeparate() {
        with(false) {
            #expect(AgentPaneHeaderState().json.objectValue?["browserOpensPreview"] == .bool(false))
            #expect(!AgentPaneHeaderState().shows(AgentPaneHeaderState(browserOpensPreview: true)))
        }
    }
}

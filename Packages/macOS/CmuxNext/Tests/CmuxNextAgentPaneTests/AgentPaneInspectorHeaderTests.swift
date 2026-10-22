import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// The Inspector behind Debug Settings `agent.inspector` (on by default): the page learns the
/// toggle from the header state (`inspector`), so with it off the header has no Inspector toggle and
/// the summary card comes back (webviews/src/agent-session/acpmux/inspector/ChatInspector.tsx).
@Suite(.serialized)
@MainActor
struct AgentPaneInspectorHeaderTests {
    private func withInspector(_ on: Bool?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.inspector.descriptor])
        TunableStore.shared.set(AgentPaneTunables.inspector.key, on.map(TunableValue.bool))
        defer { TunableStore.shared.set(AgentPaneTunables.inspector.key, nil) }
        try body()
    }

    @Test func onByDefaultThePageIsToldToOfferTheInspector() {
        withInspector(nil) {
            #expect(AgentPaneTunables.inspector.value == true)
            #expect(AgentPaneHeaderState().json.objectValue?["inspector"] == .bool(true))
        }
    }

    @Test func offThePageIsToldThereIsNoInspector() {
        withInspector(false) {
            #expect(AgentPaneHeaderState().json.objectValue?["inspector"] == .bool(false))
        }
    }
}

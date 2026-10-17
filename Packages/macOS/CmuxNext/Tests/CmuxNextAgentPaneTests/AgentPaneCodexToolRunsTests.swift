import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// Codex-style command grouping is the normal Agent Pane transcript presentation. The existing
/// Debug toggle can still opt out for comparison and troubleshooting.
@Suite(.serialized)
struct AgentPaneCodexToolRunsTests {
    @Test func groupingIsEnabledByDefault() {
        #expect(AgentPaneTunables.codexToolRuns.defaultValue == true)
        #expect(AgentPaneTunables.codexToolRuns.descriptor.key == "agentPane.debug.codexToolRuns")
    }

    @Test func debugToggleCanDisableGrouping() throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        defer { store.set(AgentPaneTunables.codexToolRuns.key, nil) }
        try #require(store.set(AgentPaneTunables.codexToolRuns.key, .bool(false)) == .bool(false))
        #expect(AgentPaneTunables.codexToolRuns.value == false)
    }
}

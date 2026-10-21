import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// A running turn lists each call by default (Leo 2026-10-20); the Debug toggle can still fold
/// runs Codex-style for comparison and troubleshooting.
@Suite(.serialized)
struct AgentPaneCodexToolRunsTests {
    @Test func turnFooterActionsDefaultRight() {
        #expect(AgentPaneTunables.turnActionsPlacement.defaultValue == .right)
        #expect(AgentPaneTunables.turnActionsPlacement.descriptor.key == "agentPane.debug.turnActionsPlacement")
    }

    @Test func groupingIsOffByDefault() {
        #expect(AgentPaneTunables.codexToolRuns.defaultValue == false)
        #expect(AgentPaneTunables.codexToolRuns.descriptor.key == "agentPane.debug.codexToolRuns")
    }

    @Test func debugToggleCanEnableGrouping() throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        defer { store.set(AgentPaneTunables.codexToolRuns.key, nil) }
        try #require(store.set(AgentPaneTunables.codexToolRuns.key, .bool(true)) == .bool(true))
        #expect(AgentPaneTunables.codexToolRuns.value == true)
    }
}

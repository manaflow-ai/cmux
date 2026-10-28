import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// Finished tool runs fold Codex-style by default (Leo and Lawrence 2026-10-20); the Debug toggle
/// can still list each call for comparison and troubleshooting.
@Suite(.serialized)
struct AgentPaneCodexToolRunsTests {
    @Test func turnFooterActionsDefaultLeft() {
        #expect(AgentPaneTunables.turnActionsPlacement.defaultValue == .left)
        #expect(AgentPaneTunables.turnActionsPlacement.descriptor.key == "agentPane.debug.turnActionsPlacement")
    }

    @Test func groupingIsOnByDefault() {
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

/// The running turn's status line is its last row by default (Claude desktop's place for it); the
/// Debug toggle can put it back over the turn's work.
@Suite(.serialized)
struct AgentPaneLiveLineTests {
    @Test func lineIsBelowByDefault() {
        #expect(AgentPaneTunables.liveLineBelow.defaultValue == true)
        #expect(AgentPaneTunables.liveLineBelow.descriptor.key == "agentPane.debug.liveLineBelow")
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.liveLineBelow" })
    }

    @Test func debugToggleCanMoveTheLineBack() throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        defer { store.set(AgentPaneTunables.liveLineBelow.key, nil) }
        try #require(store.set(AgentPaneTunables.liveLineBelow.key, .bool(false)) == .bool(false))
        #expect(AgentPaneTunables.liveLineBelow.value == false)
    }
}

import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// The answer footer's copy, retry and fork controls sit on the left by default.
@Suite(.serialized)
struct AgentPaneTurnActionsPlacementTests {
    @Test func turnFooterActionsDefaultLeft() {
        #expect(AgentPaneTunables.turnActionsPlacement.defaultValue == .left)
        #expect(AgentPaneTunables.turnActionsPlacement.descriptor.key == "agentPane.debug.turnActionsPlacement")
    }
}

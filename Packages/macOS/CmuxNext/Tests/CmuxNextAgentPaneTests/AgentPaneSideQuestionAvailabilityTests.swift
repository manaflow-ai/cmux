import CmuxNextActions
import Testing
@testable import CmuxNextAgentPane

/// `/btw` side sessions are always on: the palette's Ask a Side Question… needs only a focused
/// agent chat.
@Suite
@MainActor
struct AgentPaneSideQuestionAvailabilityTests {
    private static let sideQuestion: ActionID = "agentPane.sideQuestion"

    @Test func aFocusedChatOffersAskASideQuestion() {
        let registry = ActionRegistry.standard()
        registry.context = [.agentPaneFocused]
        #expect(registry.isAvailable(Self.sideQuestion))
        #expect(!registry.isAvailable(Self.sideQuestion, in: []))
    }
}

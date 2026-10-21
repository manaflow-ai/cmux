import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// `/btw` behind Debug Settings' Side sessions (/btw) (`agentPane.debug.sideSessions`, off by default):
/// the page learns the toggle from the header state, so with it off the composer offers no `/btw`.
@Suite(.serialized)
@MainActor
struct AgentPaneSideSessionsHeaderTests {
    private func withSideSessions(_ on: Bool, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        TunableStore.shared.set(AgentPaneTunables.sideSessions.key, on ? .bool(true) : nil)
        defer { TunableStore.shared.set(AgentPaneTunables.sideSessions.key, nil) }
        try body()
    }

    @Test func offByDefaultThePageIsToldSideSessionsAreOff() {
        withSideSessions(false) {
            #expect(AgentPaneTunables.sideSessions.value == false)
            #expect(AgentPaneHeaderState().json.objectValue?["sideSessions"] == .bool(false))
        }
    }

    @Test func onThePageIsToldSideSessionsAreOn() {
        withSideSessions(true) {
            #expect(AgentPaneHeaderState().json.objectValue?["sideSessions"] == .bool(true))
        }
    }
}

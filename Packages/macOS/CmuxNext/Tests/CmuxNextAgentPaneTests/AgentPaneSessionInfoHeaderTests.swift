import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// Session Info behind Debug Settings `agent.inspector` (on by default): the page learns the
/// toggle from the header state (wire name `inspector`), so with it off the header has no Session Info toggle and
/// the summary card comes back (webviews/src/agent-session/acpmux/session-info/SessionInfo.tsx).
@Suite(.serialized)
@MainActor
struct AgentPaneSessionInfoHeaderTests {
    private func withSessionInfo(_ on: Bool?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.sessionInfo.descriptor])
        TunableStore.shared.set(AgentPaneTunables.sessionInfo.key, on.map(TunableValue.bool))
        defer { TunableStore.shared.set(AgentPaneTunables.sessionInfo.key, nil) }
        try body()
    }

    @Test func onByDefaultThePageIsToldToOfferSessionInfo() {
        withSessionInfo(nil) {
            #expect(AgentPaneTunables.sessionInfo.value == true)
            #expect(AgentPaneHeaderState().json.objectValue?["inspector"] == .bool(true))
        }
    }

    @Test func offThePageIsToldThereIsNoSessionInfo() {
        withSessionInfo(false) {
            #expect(AgentPaneHeaderState().json.objectValue?["inspector"] == .bool(false))
        }
    }
}

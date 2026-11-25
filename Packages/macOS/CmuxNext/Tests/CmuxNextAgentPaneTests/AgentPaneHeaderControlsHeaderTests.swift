import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// The chat header's top-right controls, behind Debug Settings `agentChat.headerControls` (standard by
/// default): the page learns the layout from the header state, so open chats follow it.
@Suite(.serialized)
@MainActor
struct AgentPaneHeaderControlsHeaderTests {
    private func with(_ value: AgentPaneHeaderControls?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        TunableStore.shared.set(AgentPaneTunables.headerControls.key, value.map { TunableValue.choice($0.rawValue) })
        defer { TunableStore.shared.set(AgentPaneTunables.headerControls.key, nil) }
        try body()
    }

    @Test func standardByDefault() {
        with(nil) {
            #expect(AgentPaneTunables.headerControls.value == .standard)
            #expect(AgentPaneHeaderState().json.objectValue?["headerControls"] == .string("standard"))
        }
    }

    @Test func threeControlsReachThePageAndChangeWhatTheHeaderShows() {
        with(.trio) {
            #expect(AgentPaneHeaderState().json.objectValue?["headerControls"] == .string("trio"))
            #expect(!AgentPaneHeaderState().shows(AgentPaneHeaderState(headerControls: .standard)))
        }
    }
}

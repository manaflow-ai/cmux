import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// The chat header's top-right layout, behind Debug Settings `agentChat.topRight.consolidate` (Row by
/// default, today's buttons): the page learns the choice from the header state, so open chats follow it.
@Suite(.serialized)
@MainActor
struct AgentPaneTopRightLayoutHeaderTests {
    private func with(_ value: AgentPaneTopRightLayout?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        TunableStore.shared.set(AgentPaneTunables.topRightLayout.key, value.map { TunableValue.choice($0.rawValue) })
        defer { TunableStore.shared.set(AgentPaneTunables.topRightLayout.key, nil) }
        try body()
    }

    @Test func rowByDefaultThePageKeepsTodaysButtons() {
        with(nil) {
            #expect(AgentPaneTunables.topRightLayout.value == .row)
            #expect(AgentPaneHeaderState().json.objectValue?["topRightLayout"] == .string("row"))
        }
    }

    @Test func eachLayoutReachesThePageAndChangesWhatTheHeaderShows() {
        for layout in AgentPaneTopRightLayout.allCases where layout != .row {
            with(layout) {
                #expect(AgentPaneHeaderState().json.objectValue?["topRightLayout"] == .string(layout.rawValue))
                #expect(!AgentPaneHeaderState().shows(AgentPaneHeaderState(topRightLayout: .row)))
            }
        }
    }
}

import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// The chat header's top-right icons, behind Debug Settings `agentChat.headerIcons.contextual`
/// (standard by default): the page learns the style from the header state, so open chats follow it.
@Suite(.serialized)
@MainActor
struct AgentPaneHeaderIconsHeaderTests {
    private func with(_ value: AgentPaneHeaderIcons?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        TunableStore.shared.set(AgentPaneTunables.headerIcons.key, value.map { TunableValue.choice($0.rawValue) })
        defer { TunableStore.shared.set(AgentPaneTunables.headerIcons.key, nil) }
        try body()
    }

    @Test func standardByDefault() {
        with(nil) {
            #expect(AgentPaneTunables.headerIcons.value == .standard)
            #expect(AgentPaneHeaderState().json.objectValue?["headerIcons"] == .string("standard"))
        }
    }

    @Test func aContextualStyleReachesThePageAndChangesWhatTheHeaderShows() {
        with(.contextualPeek) {
            #expect(AgentPaneHeaderState().json.objectValue?["headerIcons"] == .string("contextualPeek"))
            #expect(!AgentPaneHeaderState().shows(AgentPaneHeaderState(headerIcons: .standard)))
        }
    }
}

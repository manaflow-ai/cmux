import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// `/btw` behind Debug Settings' Side sessions (/btw) (`agentPane.debug.sideSessions`, off by default):
/// the page learns the toggle from the header state, so with it off the composer offers no `/btw`.
@Suite(.serialized)
@MainActor
struct AgentPaneSideSessionsHeaderTests {
    private static let sideQuestion: ActionID = "agentPane.sideQuestion"

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

    @Test func sideSessionsPublishesThePaletteContextWithoutReusingWebViewBit() {
        withSideSessions(true) {
            let registry = ActionRegistry.standard()
            registry.context = [.agentPaneFocused]
            registry.publishSideSessions()
            #expect(registry.context.contains(.sideSessions))
            #expect(ActionContext.sideSessions.rawValue == 1 << 23)
            #expect(ActionContext.webViewFocused.rawValue == 1 << 20)
            #expect(registry.isAvailable(Self.sideQuestion))
            #expect(!registry.isAvailable(Self.sideQuestion, in: [.sideSessions]))
        }
    }

    @Test func sideSessionsOffRemovesThePaletteContext() {
        withSideSessions(false) {
            let registry = ActionRegistry.standard()
            registry.context = [.agentPaneFocused]
            registry.publishSideSessions()
            #expect(!registry.context.contains(.sideSessions))
            #expect(!registry.isAvailable(Self.sideQuestion))
        }
    }
}

import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// `/btw` is on by default. The explicit Debug Settings toggle remains a kill switch, and the page
/// learns the current value from the header state.
@Suite(.serialized)
@MainActor
struct AgentPaneSideSessionsHeaderTests {
    private static let sideQuestion: ActionID = "agentPane.sideQuestion"

    private func withSideSessions(_ on: Bool, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        TunableStore.shared.set(AgentPaneTunables.sideSessions.key, .bool(on))
        defer { TunableStore.shared.set(AgentPaneTunables.sideSessions.key, nil) }
        try body()
    }

    @Test func onByDefaultThePageIsToldSideSessionsAreOn() {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        defer { TunableStore.shared.set(AgentPaneTunables.sideSessions.key, nil) }
        #expect(AgentPaneTunables.sideSessions.value == true)
        #expect(AgentPaneHeaderState().json.objectValue?["sideSessions"] == .bool(true))
    }

    @Test func explicitOffThePageIsToldSideSessionsAreOff() {
        withSideSessions(false) {
            #expect(AgentPaneTunables.sideSessions.value == false)
            #expect(AgentPaneHeaderState().json.objectValue?["sideSessions"] == .bool(false))
        }
    }

    @Test func explicitOnThePageIsToldSideSessionsAreOn() {
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

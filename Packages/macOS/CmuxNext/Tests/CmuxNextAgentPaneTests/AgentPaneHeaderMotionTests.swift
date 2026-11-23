import CmuxNextDesign
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// The chat header's top-right icon motion, behind Debug Settings `agentChat.headerMotion`
/// (Thunderdome B, Leo 2026-11-05: "should they be a little more animated?"). Still by default, so
/// the shipped header is unchanged; the page learns the style from the header state.
@Suite(.serialized)
@MainActor
struct AgentPaneHeaderMotionTests {
    private func with(_ value: AgentPaneHeaderMotion?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(AgentPaneTunables.all)
        TunableStore.shared.set(AgentPaneTunables.headerMotion.key, value.map { TunableValue.choice($0.rawValue) })
        defer { TunableStore.shared.set(AgentPaneTunables.headerMotion.key, nil) }
        try body()
    }

    @Test func stillByDefault() {
        with(nil) {
            #expect(AgentPaneTunables.headerMotion.value == .still)
            #expect(AgentPaneHeaderState().json.objectValue?["headerMotion"] == .string("still"))
        }
    }

    @Test func aPickedStyleReachesThePage() {
        with(.animatedMorph) {
            #expect(AgentPaneHeaderState().json.objectValue?["headerMotion"] == .string("animated-morph"))
            #expect(!AgentPaneHeaderState().shows(AgentPaneHeaderState(headerMotion: .still)))
        }
    }

    @Test func everyStyleHasTheNameThePageReads() {
        #expect(AgentPaneHeaderMotion.allCases.map(\.rawValue) == ["still", "animated-cue", "animated-spring", "animated-morph"])
    }
}

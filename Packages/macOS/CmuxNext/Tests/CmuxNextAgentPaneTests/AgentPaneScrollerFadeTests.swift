import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// The agent chat's scrollbars fade at rest by default (Lawrence 2026-10-23, msg 11494: "auto-fades
/// away"); the Debug toggle keeps them shown (Leo 2026-10-21), and the page hears it with the theme
/// (`scrollerFade`).
@Suite(.serialized)
@MainActor
struct AgentPaneScrollerFadeTests {
    @Test func theScrollbarFadesAtRestByDefault() {
        #expect(AgentPaneTunables.scrollerFade.defaultValue == true)
        #expect(AgentPaneTunables.scrollerFade.descriptor.key == "agentPane.debug.scrollerFade")
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.scrollerFade" })
    }

    @Test func thePageHearsTheFadeWithTheTheme() throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        defer { store.set(AgentPaneTunables.scrollerFade.key, nil) }
        #expect(AgentPaneTheme.values(.unresolved)["scrollerFade"] as? Bool == true)
        try #require(store.set(AgentPaneTunables.scrollerFade.key, .bool(false)) == .bool(false))
        #expect(AgentPaneTheme.values(.unresolved)["scrollerFade"] as? Bool == false)
    }
}

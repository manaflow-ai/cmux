import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// The agent chat transcript's scrollbar stays shown by default (Leo 2026-10-21); the Debug toggle
/// makes it fade at rest, and the page hears it with the theme (`scrollerFade`).
@Suite(.serialized)
@MainActor
struct AgentPaneScrollerFadeTests {
    @Test func theScrollbarStaysShownByDefault() {
        #expect(AgentPaneTunables.scrollerFade.defaultValue == false)
        #expect(AgentPaneTunables.scrollerFade.descriptor.key == "agentPane.debug.scrollerFade")
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.debug.scrollerFade" })
    }

    @Test func thePageHearsTheFadeWithTheTheme() throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        defer { store.set(AgentPaneTunables.scrollerFade.key, nil) }
        #expect(AgentPaneTheme.values(.unresolved)["scrollerFade"] as? Bool == false)
        try #require(store.set(AgentPaneTunables.scrollerFade.key, .bool(true)) == .bool(true))
        #expect(AgentPaneTheme.values(.unresolved)["scrollerFade"] as? Bool == true)
    }
}

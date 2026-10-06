import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// At launch, an agent tab outside the focused pane makes its web view after
/// the launch's first pane content (the focused terminal's first frame), so
/// its WKProcessPool and AgentPaneView.init do not delay that terminal. A
/// focused agent tab, or a launch whose focus is not known, does not wait.
@MainActor
@Suite struct AgentTabLaunchDeferralTests {
    private func store() -> AgentTabStore {
        AgentTabStore(tag: nil, registry: .standard(), environment: AgentTabFixture.mock, linkScheme: nil)
    }

    @Test func anAgentTabBesideTheFocusedPaneWaitsForTheFirstPaneContent() {
        let tabs = store(), reveal = LaunchReveal()
        var shown = 0
        #expect(tabs.deferAtLaunch("chat", reveal: reveal, focusedPane: "terminal-pane", pane: "agent-pane") { shown += 1 })
        // A second show before the content arrives waits on the same turn.
        #expect(tabs.deferAtLaunch("chat", reveal: reveal, focusedPane: "terminal-pane", pane: "agent-pane") { shown += 1 })
        #expect(shown == 0)
        reveal.markReady(.pane)
        #expect(shown == 1)
        #expect(!tabs.deferAtLaunch("chat", reveal: reveal, focusedPane: "terminal-pane", pane: "agent-pane") { shown += 1 })
    }

    @Test func theFocusedAgentTabMakesItsViewAtOnce() {
        let tabs = store(), reveal = LaunchReveal()
        #expect(!tabs.deferAtLaunch("chat", reveal: reveal, focusedPane: "agent-pane", pane: "agent-pane") {})
    }

    @Test func anUnknownFocusDoesNotWait() {
        let tabs = store(), reveal = LaunchReveal()
        #expect(!tabs.deferAtLaunch("chat", reveal: reveal, focusedPane: nil, pane: "agent-pane") {})
    }

    @Test func afterTheLaunchNothingWaits() {
        let tabs = store(), reveal = LaunchReveal()
        reveal.markAllReady()
        #expect(!tabs.deferAtLaunch("chat", reveal: reveal, focusedPane: "terminal-pane", pane: "agent-pane") {})
    }
}

import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextApp

/// A tab an agent drove never gets saved passwords filled again, including
/// the page that replaces it after hibernation or a deferred start.
@MainActor @Suite struct AgentDrivenTabTests {
    func page() -> MockBrowserTab {
        MockBrowserTab(configuration: BrowserTabConfiguration(), engineKind: .cef, completesNavigationsImmediately: true)
    }

    @Test func theMarkFollowsTheTabToItsNextPage() {
        let cache = TabContentCache(daemon: DaemonService())
        let first = page()
        cache.install(first, for: "tab")
        cache.markAgentDriven("tab")
        #expect(first.commands == [.markAgentDriven])

        let next = page()
        cache.swapPage("tab", with: next)
        #expect(next.commands.contains(.markAgentDriven))

        let other = page()
        cache.install(other, for: "other")
        #expect(!other.commands.contains(.markAgentDriven), "only the tab the agent drove")
    }

    @Test func aClosedTabForgetsTheMark() {
        let cache = TabContentCache(daemon: DaemonService())
        cache.install(page(), for: "tab")
        cache.markAgentDriven("tab")
        cache.release("tab")
        #expect(cache.agentDrivenTabs.isEmpty)
    }
}

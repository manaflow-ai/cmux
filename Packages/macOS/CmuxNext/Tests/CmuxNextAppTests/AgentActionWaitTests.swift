@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// An agent's page action right after `cmux browser open` (cx-qncg) waits,
/// bounded, for the tab's page to exist and for its pending navigation to
/// finish, as the auto engine, Aside and ChatGPT do. Before, it failed with
/// "The browser page is still starting; retry", then "Element not found".
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentActionWaitTests {
    private func page() -> MockBrowserTab {
        MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false).makeMockTab(BrowserTabConfiguration())
    }

    @Test func anActionWaitsForThePageThatIsStillStarting() async {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let made = page()
        let waiting = Task { await AppBrowserPage.awaitPage("tab", services: services, within: .seconds(30)) }
        await Task.yield()
        services.cache.install(made, for: "tab")
        #expect(await waiting.value === made)
    }

    @Test func aPageThatNeverStartsEndsAtTheBound() async {
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(await AppBrowserPage.awaitPage("tab", services: services, within: .milliseconds(50)) == nil)
    }

    @Test func anActionWaitsForThePendingNavigation() async {
        let tab = page()
        let id = tab.makeNavigationID()
        tab.simulate(.started(id, url: URL(string: "https://a.test/")))
        let waiting = Task { await AppBrowserPage.awaitPendingNavigation(tab, within: .seconds(30)) }
        await Task.yield()
        tab.simulate(.committed(id, url: URL(string: "https://a.test/")))
        tab.simulate(.finished(id))
        #expect(await waiting.value == true)
    }

    @Test func aNavigationThatNeverEndsEndsAtTheBound() async {
        let tab = page()
        tab.simulate(.started(tab.makeNavigationID(), url: URL(string: "https://a.test/")))
        #expect(await AppBrowserPage.awaitPendingNavigation(tab, within: .milliseconds(50)) == false)
    }
}

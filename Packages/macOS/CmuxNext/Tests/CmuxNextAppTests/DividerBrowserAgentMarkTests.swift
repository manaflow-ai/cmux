@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Testing

/// Insert New ▸ Browser from the CLI, MCP or a script is an agent's tab (plans/cmux-next/browser.md): its split's
/// stand-in page and then the daemon tab's page are marked before they exist, by the new pane's client-minted id,
/// so no saved password fills and the agent's URL rules hold from the first load (review of #37733).
@MainActor struct DividerBrowserAgentMarkTests {
    private func cache() -> TabContentCache {
        let stores = BrowserSharedStores.inMemory()
        return TabContentCache(daemon: DaemonService(),
                               cef: CEFEngine(layout: nil, stores: stores, signInCallbacks: CEFSignInCallbacks()),
                               fileInput: NoFileInput())
    }

    @Test func theStandInAndThenTheDaemonsTabOfAMarkedPaneAreAgentDriven() {
        let cache = cache(), pane = "pane_" + String(repeating: "a", count: 32)
        cache.markAgentDriven(pane: pane, machine: "local")

        cache.claimAgentDriven(surface: ProvisionalTab().surface, key: "stand-in", pane: pane, machine: "local")
        #expect(cache.agentDrivenTabs.contains("stand-in"))

        cache.claimAgentDriven(surface: SurfaceID(rawValue: 41), key: "daemon-tab", pane: pane, machine: "local")
        #expect(cache.agentDrivenTabs.contains("daemon-tab"))

        // The daemon's tab ended the mark: a tab the person opens in that pane later is theirs.
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 42), key: "later-tab", pane: pane, machine: "local")
        #expect(!cache.agentDrivenTabs.contains("later-tab"))
    }

    @Test func aPersonsSplitAndAnotherMachinesPaneAreNotAgentDriven() {
        let cache = cache(), pane = "pane_" + String(repeating: "b", count: 32)
        cache.markAgentDriven(pane: pane, machine: "local")

        cache.claimAgentDriven(surface: SurfaceID(rawValue: 51), key: "other-pane", pane: "pane_" + String(repeating: "c", count: 32), machine: "local")
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 52), key: "other-machine", pane: pane, machine: "remote")
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 53), key: "no-pane", pane: nil, machine: "local")

        #expect(cache.agentDrivenTabs.isDisjoint(with: ["other-pane", "other-machine", "no-pane"]))
    }
}

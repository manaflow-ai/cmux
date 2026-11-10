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

        // A tab the person opens in the pane before the agent's one mounts is marked too: it cannot take the mark.
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 40), key: "persons-tab", pane: pane, machine: "local")
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 41), key: "daemon-tab", pane: pane, machine: "local")
        #expect(cache.agentDrivenTabs.isSuperset(of: ["persons-tab", "daemon-tab"]))

        // The reply ended the mark: a tab the person opens in that pane later is theirs.
        cache.settleAgentDriven(pane: pane, machine: "local", surface: SurfaceID(rawValue: 41))
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 42), key: "later-tab", pane: pane, machine: "local")
        #expect(!cache.agentDrivenTabs.contains("later-tab"))
        #expect(cache.agentDrivenSurfaces.isEmpty)
    }

    @Test func aReplyBeforeTheDaemonsTabMountsMarksItsSurface() {
        let cache = cache(), pane = "pane_" + String(repeating: "d", count: 32)
        cache.markAgentDriven(pane: pane, machine: "local")
        cache.settleAgentDriven(pane: pane, machine: "local", surface: SurfaceID(rawValue: 61))

        cache.claimAgentDriven(surface: SurfaceID(rawValue: 62), key: "persons-tab", pane: pane, machine: "local")
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 61), key: "daemon-tab", pane: pane, machine: "local")
        #expect(cache.agentDrivenTabs.contains("daemon-tab"))
        #expect(!cache.agentDrivenTabs.contains("persons-tab"))
    }

    @Test func anotherMachinesTabWithTheSameSurfaceNeverTakesASettledMark() {
        // Surface numbers are only unique on their own daemon: a remote tab numbered like the agent's, mounting
        // between the reply and the agent's tab, must not take its mark (review of #37733 at ce9b6440).
        let cache = cache(), pane = "pane_" + String(repeating: "f", count: 32)
        cache.markAgentDriven(pane: pane, machine: "local")
        cache.settleAgentDriven(pane: pane, machine: "local", surface: SurfaceID(rawValue: 81))

        cache.claimAgentDriven(surface: SurfaceID(rawValue: 81), key: "remote-tab", pane: nil, machine: "remote")
        cache.claimAgentDriven(surface: SurfaceID(rawValue: 81), key: "agent-tab", pane: pane, machine: "local")
        #expect(!cache.agentDrivenTabs.contains("remote-tab"))
        #expect(cache.agentDrivenTabs.contains("agent-tab"))
    }

    @Test func aSplitThatFailedWithNoAnswerKeepsItsPaneMarked() {
        // A timeout or a lost connection can follow the daemon's commit: the pane may still arrive, and is the agent's.
        let cache = cache(), pane = "pane_" + String(repeating: "e", count: 32)
        cache.markAgentDriven(pane: pane, machine: "local")

        cache.claimAgentDriven(surface: SurfaceID(rawValue: 71), key: "late-daemon-tab", pane: pane, machine: "local")
        #expect(cache.agentDrivenTabs.contains("late-daemon-tab"))
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

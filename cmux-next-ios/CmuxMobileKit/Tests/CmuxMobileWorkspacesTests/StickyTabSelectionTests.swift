import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

#if os(iOS)
import CmuxMobileAgentChat

/// Leo, 2026-11-21: "i lost connection with cosmic gray or some s*** refreshed or the connection f***ing
/// lagged and then it brought me out of the terminal tab and into a browser tab". A disconnect, a resync
/// that publishes the workspace without the tab on screen, and a reconnect leave the person on their tab.
@MainActor @Suite(.serialized) struct StickyTabSelectionTests {
    static let mac = "mac-studio"

    struct Rig {
        let store: AppStore
        let source: WorkspaceTabsSource
        let clock: GridTestClock
    }

    static func rig(showsBrowsers: Bool = true) -> Rig {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        store.macConnection[mac] = .connected
        let clock = GridTestClock()
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", sessions: AgentSessionDirectory(), clock: clock)
        // Selection holds must not depend on the test host's saved pane filter.
        source.paneFilter = PaneFilterSetting(defaults: nil)
        source.paneFilter.showsBrowsers = showsBrowsers
        source.opened()
        source.activate("t-zsh")
        return Rig(store: store, source: source, clock: clock)
    }

    /// The Mac's list for this workspace without `tabID` (a partial tree after a resync).
    static func publish(_ store: AppStore, without tabID: String?) {
        let full = AppStore.mock(tabMemory: .inMemory([:])).workspaces.filter { $0.macID == mac }
        let next = full.map { workspace -> Workspace in
            var workspace = workspace
            if let tabID { workspace.tabs.removeAll { $0.id == tabID } }
            return workspace
        }
        store.replaceWorkspaces(macID: mac, with: next)
    }

    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test(arguments: [false, true]) func disconnectResyncReconnectKeepsTheTabOnScreen(showsBrowsers: Bool) async {
        let rig = Self.rig(showsBrowsers: showsBrowsers)
        #expect(rig.source.activeTabID == "t-zsh")
        // The link drops; a resync publishes the workspace without the terminal tab.
        rig.store.macConnection[Self.mac] = .connecting
        Self.publish(rig.store, without: "t-zsh")
        rig.source.refreshTabs()
        #expect(rig.source.activeTabID == "t-zsh")
        #expect(rig.source.tabs.map(\.id).contains("t-zsh"))
        // However long the link stays down, the tab is not let go.
        await Self.settle()
        rig.clock.advance(by: .seconds(120))
        await Self.settle()
        #expect(rig.source.activeTabID == "t-zsh")
        // Reconnect: the first tree is still partial, then the full one comes.
        rig.store.macConnection[Self.mac] = .connected
        rig.source.refreshTabs()
        await Self.settle()
        rig.clock.advance(by: .seconds(3))
        await Self.settle()
        #expect(rig.source.activeTabID == "t-zsh")
        Self.publish(rig.store, without: nil)
        rig.source.refreshTabs()
        #expect(rig.source.activeTabID == "t-zsh")
        #expect(rig.source.allTabs.map(\.id) == ["t-claude", "t-zsh", "t-docs"])
        #expect(rig.source.tabs.map(\.id) == (showsBrowsers ? ["t-claude", "t-zsh", "t-docs"] : ["t-claude", "t-zsh"]))
        // The tab comes back: no stale hold clock fires later.
        rig.clock.advance(by: .seconds(60))
        await Self.settle()
        #expect(rig.source.activeTabID == "t-zsh")
        #expect(rig.store.lastActiveTabByWorkspace["ws-cmux"] == "t-zsh")
    }

    @Test func aTabTheLinkedMacDropsForGoodMovesToItsNeighbour() async {
        let rig = Self.rig()
        Self.publish(rig.store, without: "t-zsh")
        rig.source.refreshTabs()
        #expect(rig.source.activeTabID == "t-zsh")
        await Self.settle()
        rig.clock.advance(by: WorkspaceTabsSource.selectionHoldGrace)
        await Self.settle()
        // Its neighbour (the tab that took its place), never the Mac's focused tab.
        #expect(rig.source.activeTabID == "t-docs")
        #expect(!rig.source.tabs.map(\.id).contains("t-zsh"))
    }

    @Test func aPickedTabIsNeverOverriddenByTheHold() {
        let rig = Self.rig()
        rig.store.macConnection[Self.mac] = .connecting
        Self.publish(rig.store, without: "t-zsh")
        rig.source.refreshTabs()
        rig.source.activate("t-claude")
        rig.source.refreshTabs()
        #expect(rig.source.activeTabID == "t-claude")
        #expect(!rig.source.tabs.map(\.id).contains("t-zsh"))
    }

    @Test func neighbourIsTheTabThatTookItsPlace() {
        let tabs = AppStore.mock(tabMemory: .inMemory([:])).workspace(id: "ws-cmux")?.tabs ?? []
        #expect(WorkspaceTabsSource.neighbour(at: 1, in: tabs)?.id == "t-zsh")
        #expect(WorkspaceTabsSource.neighbour(at: 9, in: tabs)?.id == "t-docs")
        #expect(WorkspaceTabsSource.neighbour(at: 0, in: []) == nil)
    }
}
#endif

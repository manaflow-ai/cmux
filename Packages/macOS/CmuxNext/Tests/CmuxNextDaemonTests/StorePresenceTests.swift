import Testing
@testable import CmuxNextDaemon

/// Agent presence is live-only (cx-gg84): when the store may have missed a
/// clear (a lost connection, a daemon shutdown, dropped events), no tab keeps
/// showing what an agent was doing. The next hook event brings it back.
@MainActor
struct StorePresenceTests {
    private func storeWithPresence() -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        store.apply(.agentPresenceChanged(AgentPresence(surface: 1, activity: .editing, agent: "claude", path: "/r/a.rs")))
        return store
    }

    @Test(arguments: [DaemonEvent.disconnected(reason: "socket closed"), .daemonShutdown, .overflow("inbox full")])
    func presenceClearsWhenAClearMayHaveBeenMissed(_ event: DaemonEvent) {
        let store = storeWithPresence()
        #expect(store.tab(surface: 1)?.presence?.activity == .editing)
        store.apply(event)
        #expect(store.tab(surface: 1)?.presence == nil)
    }

    private func tree(surfaces: [SurfaceID]) -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: surfaces.map { TabSnapshot(surface: $0) })
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    private func presence(_ surface: SurfaceID, _ activity: AgentPresence.Activity? = .editing) -> DaemonEvent {
        .agentPresenceChanged(AgentPresence(surface: surface, activity: activity, agent: "claude", path: "/r/a.rs"))
    }

    /// An agent hook can fire right after its terminal is created, before the store has indexed the
    /// tab (a fresh tab, a restored session, a hook replayed on reconnect). Presence is not in any
    /// snapshot, so the event is the only time the store hears of it.
    @Test func presenceForATabTheStoreHasNotIndexedYetLandsWhenTheTabArrives() {
        let store = DaemonStore()
        store.apply(snapshot: tree(surfaces: [1]))
        store.apply(presence(2))
        #expect(store.tab(surface: 2) == nil)

        store.apply(snapshot: tree(surfaces: [1, 2]))
        #expect(store.tab(surface: 2)?.presence?.activity == .editing)
        #expect(store.tab(surface: 1)?.presence == nil)
    }

    @Test func aClearForAnUnindexedTabDropsTheHeldPresence() {
        let store = DaemonStore()
        store.apply(presence(2))
        store.apply(presence(2, nil))
        store.apply(snapshot: tree(surfaces: [2]))
        #expect(store.tab(surface: 2)?.presence == nil)
    }

    @Test func heldPresenceDoesNotSurviveAMissedClear() {
        let store = DaemonStore()
        store.apply(presence(2))
        store.apply(.disconnected(reason: "socket closed"))
        store.apply(snapshot: tree(surfaces: [2]))
        #expect(store.tab(surface: 2)?.presence == nil)
    }

    @Test func presenceForSurfacesThatNeverArriveIsBounded() {
        let store = DaemonStore()
        for raw in UInt64(100)..<UInt64(5_100) { store.apply(presence(SurfaceID(rawValue: raw))) }
        #expect(store.heldPresenceCount <= DaemonStore.heldPresenceLimit)
    }
}

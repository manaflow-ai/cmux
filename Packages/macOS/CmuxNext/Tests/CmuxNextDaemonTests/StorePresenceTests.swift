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
}

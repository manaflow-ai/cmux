@testable import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Testing

/// What `snapshot.get` says while the tree is the daemon's launch snapshot (`DaemonStore.applyProvisional`): drawn
/// before the daemon answered, its panes may not exist in the daemon yet. An agent or the CLI that waits for
/// `loaded` and `daemon_state: "connected"` must not be told the tree is ready then (the "unknown pane" of the first
/// open, vw4a-ctl-2 and vw4a-div-2-r2, 2026-11-27: the readiness wait passed on a tree whose pane the daemon then
/// retired). The socket connects before the first live snapshot applies, so "connected" alone said nothing.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ControlTopologyLaunchSnapshotTests {
    static let tree = DaemonTree(workspaces: [
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "work", screens: [
            ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), columns: [],
                           panes: [PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 101))])], floating: []),
        ]),
    ])

    static func reported(_ store: DaemonStore) -> (loaded: CmuxNextSettings.JSONValue?, state: CmuxNextSettings.JSONValue?) {
        let json = ControlTopology(store: store, selectedTab: { $0.tabs.first?.id }).json
        return (json["loaded"], json["daemon_state"])
    }

    @Test func aLaunchSnapshotIsNeitherLoadedNorConnectedUntilTheLiveTreeApplies() {
        let store = DaemonStore()
        // As `DaemonService.showLaunchSnapshot`: the saved tree first, then the socket connects.
        store.applyProvisional(snapshot: Self.tree)
        #expect(Self.reported(store).loaded == CmuxNextSettings.JSONValue.bool(false))
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        let early = Self.reported(store)
        #expect(early.loaded == CmuxNextSettings.JSONValue.bool(false), "snapshot.get said loaded on the launch snapshot")
        #expect(early.state == CmuxNextSettings.JSONValue.string("connecting"), "snapshot.get said \(String(describing: early.state)) on the launch snapshot")
        // The first live snapshot: now the tree is the daemon's.
        store.apply(snapshot: Self.tree)
        let live = Self.reported(store)
        #expect(live.loaded == CmuxNextSettings.JSONValue.bool(true))
        #expect(live.state == CmuxNextSettings.JSONValue.string("connected"))
    }
}

@testable import CmuxNextDaemon
import Testing

/// A watcher of the few panes it tracks (InternalPageTabStore's page tabs) asks the store about
/// those panes, never the session's (review 1 of pl-script-s1, perf-lead.md section 2 row 29 c:
/// the page tab store built the set of every pane of every workspace on each tree change and
/// observed every workspace's screens and every screen's panes). The store answers by lookup, and
/// the revision it watches changes when a pane comes or goes, tabs or not.
@MainActor @Suite struct StoreLivePaneTests {
    private static let workspaces = 500

    private static func workspace(_ index: Int, panes: Int = 1) -> WorkspaceSnapshot {
        let base = UInt64(index * 100)
        let list = (0..<panes).map { slot in
            PaneSnapshot(id: PaneID(rawValue: base + 1 + UInt64(slot) * 10),
                         tabs: slot == 0 ? [TabSnapshot(surface: SurfaceID(rawValue: base + 5))] : [])
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(list[0].id), panes: list)
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
    }

    private func loadedStore() -> DaemonStore {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: (0..<Self.workspaces).map { Self.workspace($0, panes: $0 == 7 ? 2 : 1) }))
        return store
    }

    @Test func askingAboutAPaneReadsNoOtherPane() throws {
        let store = loadedStore()
        let tracked = try #require(store.workspaces.last?.screens.first?.panes.first)
        let reads = store.livePaneReads
        #expect(store.liveTreeLists(pane: tracked.id) == true)
        #expect(store.liveTreeLists(pane: "pane:999999") == false)
        #expect(store.livePaneReads - reads == 0, "two questions read \(store.livePaneReads - reads) of 501 panes")
    }

    @Test func aPaneWithNoTabsThatGoesChangesTheWatchedRevision() throws {
        let store = loadedStore()
        let empty = try #require(store.workspaces[7].screens.first?.panes.last)
        #expect(empty.tabs.isEmpty)
        let before = store.liveTabListRevision
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneClosed(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 703), screen: ScreenID(rawValue: 702), pane: empty.handle, index: nil,
            entity: PaneSnapshot(id: empty.handle, tabs: []), clientTransactionID: nil)))])
        #expect(store.liveTabListRevision != before, "a watcher of panes did not wake when a pane went")
        #expect(store.liveTreeLists(pane: empty.id) == false)
    }
}

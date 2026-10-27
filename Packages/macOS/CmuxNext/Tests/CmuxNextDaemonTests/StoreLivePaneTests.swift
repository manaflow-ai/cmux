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

    @Test func aPaneIsListedByItsIdUntilItsLastRecordGoes() throws {
        let store = loadedStore()
        let tracked = try #require(store.workspaces.last?.screens.first?.panes.first)
        #expect(store.liveTreeLists(pane: tracked.id) == true)
        #expect(store.liveTreeLists(pane: "pane:999999") == false)
    }

    /// A pane moved to another workspace: its pane-added in the target indexes a second record of
    /// the same id before the source's pane-closed drops the first. The pane stays listed, so the
    /// page tab store keeps the page tabs of the live pane.
    @Test func aPaneMovedBetweenWorkspacesStaysListed() throws {
        let store = loadedStore()
        let resource = ResourceID(rawValue: "pane_moving")
        let movingID = PaneID(rawValue: 9001)
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 3), screen: ScreenID(rawValue: 2), pane: movingID, index: 1,
            entity: PaneSnapshot(id: movingID, resourceID: resource, tabs: []), clientTransactionID: nil)))])
        let id = try #require(store.pane(movingID)?.id)
        // The move: the target workspace gets the pane, then the source closes its record.
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: .paneAdded(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 103), screen: ScreenID(rawValue: 102), pane: PaneID(rawValue: 9002), index: 1,
            entity: PaneSnapshot(id: PaneID(rawValue: 9002), resourceID: resource, tabs: []), clientTransactionID: nil)))])
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 3, event: .paneClosed(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 3), screen: ScreenID(rawValue: 2), pane: movingID, index: nil,
            entity: PaneSnapshot(id: movingID, resourceID: resource, tabs: []), clientTransactionID: nil)))])
        #expect(store.liveTreeLists(pane: id) == true, "the moved pane's id was dropped with its old record")
        // Its last record goes: no longer listed.
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 4, event: .paneClosed(PaneDelta(
            workspace: WorkspaceHandle(rawValue: 103), screen: ScreenID(rawValue: 102), pane: PaneID(rawValue: 9002), index: nil,
            entity: PaneSnapshot(id: PaneID(rawValue: 9002), resourceID: resource, tabs: []), clientTransactionID: nil)))])
        #expect(store.liveTreeLists(pane: id) == false, "a pane whose last record went is still listed")
    }

    /// Both records of a moving pane go in one publish (one batch): the watched revision still
    /// changes, so a watcher of panes learns that the pane is gone.
    @Test func bothRecordsOfAMovingPaneGoingInOneBatchChangeTheWatchedRevision() throws {
        let store = loadedStore()
        let resource = ResourceID(rawValue: "pane_twice")
        let first = PaneID(rawValue: 9101), second = PaneID(rawValue: 9102)
        _ = store.apply(batch: [
            DaemonEventEnvelope(sequence: 1, event: .paneAdded(PaneDelta(
                workspace: WorkspaceHandle(rawValue: 3), screen: ScreenID(rawValue: 2), pane: first, index: 1,
                entity: PaneSnapshot(id: first, resourceID: resource, tabs: []), clientTransactionID: nil))),
            DaemonEventEnvelope(sequence: 2, event: .paneAdded(PaneDelta(
                workspace: WorkspaceHandle(rawValue: 103), screen: ScreenID(rawValue: 102), pane: second, index: 1,
                entity: PaneSnapshot(id: second, resourceID: resource, tabs: []), clientTransactionID: nil))),
        ])
        let id = try #require(store.pane(first)?.id)
        let before = store.liveTabListRevision
        _ = store.apply(batch: [
            DaemonEventEnvelope(sequence: 3, event: .paneClosed(PaneDelta(
                workspace: WorkspaceHandle(rawValue: 3), screen: ScreenID(rawValue: 2), pane: first, index: nil,
                entity: PaneSnapshot(id: first, resourceID: resource, tabs: []), clientTransactionID: nil))),
            DaemonEventEnvelope(sequence: 4, event: .paneClosed(PaneDelta(
                workspace: WorkspaceHandle(rawValue: 103), screen: ScreenID(rawValue: 102), pane: second, index: nil,
                entity: PaneSnapshot(id: second, resourceID: resource, tabs: []), clientTransactionID: nil))),
        ])
        #expect(store.liveTreeLists(pane: id) == false)
        #expect(store.liveTabListRevision != before, "the two records cancelled in the list digest: no watcher woke")
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

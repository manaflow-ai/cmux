@testable import CmuxNextDaemon
import Testing

/// A burst of script or daemon changes costs what changed (PL-script's findings: a burst of renames
/// and moves was O(session) per event). 500 renames index the renamed workspaces only; 500 moves
/// in one batch flatten the sidebar once, in one pass over the workspaces.
@MainActor @Suite struct StoreBurstCostTests {
    private static let size = 500

    private func workspace(_ index: Int, name: String? = nil, group: WorkspaceGroupID? = nil) -> WorkspaceSnapshot {
        let base = UInt64(index * 100)
        let pane = PaneSnapshot(id: PaneID(rawValue: base + 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 10))])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(PaneID(rawValue: base + 1)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: name ?? "w\(index)", screens: [screen], group: group)
    }

    private func loadedStore() -> DaemonStore {
        let store = DaemonStore()
        let groups = (0..<8).map { WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: "g\($0)"), name: "g\($0)", index: $0) }
        store.apply(snapshot: DaemonTree(workspaces: (0..<Self.size).map { workspace($0, group: WorkspaceGroupID(rawValue: "g\($0 % 8)")) }, groups: groups))
        return store
    }

    @Test func fiveHundredRenamesInOneBatchIndexOnlyTheRenamedWorkspaces() {
        let store = loadedStore()
        let indexed = store.index.indexedRecords
        let visits = store.sidebarWorkspaceVisits
        let batch = (0..<Self.size).map { index in
            DaemonEventEnvelope(sequence: UInt64(index + 1), event: .workspaceRenamed(WorkspaceDelta(
                workspace: WorkspaceHandle(rawValue: UInt64(index * 100 + 3)), index: nil,
                entity: workspace(index, name: "renamed \(index)", group: WorkspaceGroupID(rawValue: "g\(index % 8)")),
                workspaceRevision: store.workspaceRevision + UInt64(index) + 1)))
        }
        _ = store.apply(batch: batch)
        #expect(store.workspaces[42].name == "renamed 42")
        // Each rename re-indexes its own workspace subtree (4 records), never the session.
        #expect(store.index.indexedRecords - indexed <= Self.size * 4)
        #expect(store.sidebarWorkspaceVisits == visits, "a rename does not flatten the sidebar")
    }

    @Test func fiveHundredMovesInOneBatchFlattenTheSidebarOnceInOnePass() {
        let store = loadedStore()
        let visits = store.sidebarWorkspaceVisits
        let batch = (0..<Self.size).map { step in
            let index = Self.size - 1 - step
            return DaemonEventEnvelope(sequence: UInt64(step + 1), event: .workspaceMoved(WorkspaceDelta(
                workspace: WorkspaceHandle(rawValue: UInt64(index * 100 + 3)), index: 0,
                entity: workspace(index, group: WorkspaceGroupID(rawValue: "g\(index % 8)")), workspaceRevision: store.workspaceRevision + UInt64(step) + 1)))
        }
        _ = store.apply(batch: batch)
        #expect(store.workspaces.first?.name == "w0")
        // One flattening of the batch, and it visits each workspace a constant number of times
        // (not once per group).
        #expect(store.sidebarWorkspaceVisits - visits <= Self.size * 2)
        #expect(store.sidebarSections.count == 9)
        #expect(store.sidebarSections.dropFirst().allSatisfy { $0.workspaces.count == Self.size / 8 || $0.workspaces.count == Self.size / 8 + 1 })
    }
}

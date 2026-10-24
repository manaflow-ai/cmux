@testable import CmuxNextDaemon
import Testing

/// A snapshot apply costs what changed, not the session (plans/cmux-next/main-thread-budget.md; the
/// every-action sweep's daemon-store-apply group: newWindow stalled 243 ms and workspace.duplicate
/// timed out at STRESS while every `tree-changed` re-applied, re-indexed and re-laid every record).
@MainActor @Suite struct SnapshotApplyCostTests {
    /// One workspace: one screen, one pane, `tabs` tabs; surfaces unique per workspace.
    private func workspace(_ index: Int, tabs: Int = 3, title: String = "t") -> WorkspaceSnapshot {
        let base = UInt64(index * 100)
        let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                tabs: (0..<tabs).map { TabSnapshot(surface: SurfaceID(rawValue: base + 10 + UInt64($0)), title: "\(title) \($0)") })
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(PaneID(rawValue: base + 1)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
    }

    private func session(_ count: Int, changing changed: Int? = nil) -> DaemonTree {
        DaemonTree(workspaces: (0..<count).map { workspace($0, title: $0 == changed ? "renamed" : "t") })
    }

    @Test(arguments: [50, 500])
    func aSnapshotThatChangedOneWorkspaceIndexesOnlyThatWorkspace(sessionSize: Int) {
        let store = DaemonStore()
        store.apply(snapshot: session(sessionSize))
        let before = store.index.indexedRecords
        store.apply(snapshot: session(sessionSize, changing: 7))
        let indexed = store.index.indexedRecords - before
        // One workspace record, its screen, its pane and its 3 tabs.
        #expect(indexed <= 6, "a one-workspace change indexed \(indexed) records in a \(sessionSize)-workspace session")
        #expect(store.workspaces.count == sessionSize)
        #expect(store.workspaces[7].screens.first?.panes.first?.tabs.first?.title == "renamed 0")
        #expect(store.index.tabsBySurface.count == sessionSize * 3)
    }

    @Test func anUnchangedSnapshotIndexesNothing() {
        let store = DaemonStore()
        store.apply(snapshot: session(200))
        let before = store.index.indexedRecords
        store.apply(snapshot: session(200))
        #expect(store.index.indexedRecords - before == 0)
    }

    @Test func anEventSinceTheLastSnapshotIsCorrectedByTheNextOneEvenWhenTheDaemonsCopyDidNotChange() throws {
        let store = DaemonStore()
        store.apply(snapshot: session(20))
        // An event renames a tab; the next snapshot still has the old title (the daemon reverted it,
        // or the event was not the daemon's): the snapshot wins for that workspace.
        let surface = SurfaceID(rawValue: 3 * 100 + 10)
        _ = store.apply(.titleChanged(surface: surface, title: "from an event"))
        #expect(store.index.tabsBySurface[surface]?.title == "from an event")
        store.apply(snapshot: session(20))
        #expect(store.index.tabsBySurface[surface]?.title == "t 0")
    }

    @Test func aNewConnectionsFirstSnapshotAppliesInFull() {
        let store = DaemonStore()
        store.apply(snapshot: session(30))
        store.connectionEpoch += 1
        let before = store.index.indexedRecords
        store.apply(snapshot: session(30))
        #expect(store.index.indexedRecords - before == 30 * 6, "nothing the last connection applied is trusted")
    }

    @Test func aSnapshotDiffComputedAgainstAnOlderMemoIsRecomputed() {
        let store = DaemonStore()
        store.apply(snapshot: session(20))
        let stale = SnapshotDiff(revision: store.snapshotMemo.revision &- 1, changed: [])
        store.apply(snapshot: session(20, changing: 5), diff: stale)
        #expect(store.workspaces[5].screens.first?.panes.first?.tabs.first?.title == "renamed 0",
                "a diff of another memo revision is not trusted")
    }

    @Test func removedAndAddedAndReorderedWorkspacesApply() {
        let store = DaemonStore()
        store.apply(snapshot: session(10))
        var next = session(10).workspaces
        next.remove(at: 4)
        next.swapAt(0, 1)
        next.append(workspace(42))
        store.apply(snapshot: DaemonTree(workspaces: next))
        #expect(store.workspaces.map(\.name) == next.map(\.name))
        #expect(store.index.workspacesByHandle[WorkspaceHandle(rawValue: 4 * 100 + 3)] == nil)
        #expect(store.index.tabsBySurface[SurfaceID(rawValue: 4 * 100 + 10)] == nil)
        #expect(store.index.tabsBySurface[SurfaceID(rawValue: 42 * 100 + 10)] != nil)
    }
}

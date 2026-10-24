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

    /// Review 1 of pl-main-bc: after the off-main diff, the main actor still compared every
    /// workspace's whole snapshot with the memo (recordSnapshotMemo) and copied the memo's
    /// dictionary: O(session) on main per snapshot. A live resync hands main its diff; main walks
    /// no workspace snapshot for the memo.
    @Test(arguments: [50, 500])
    func aLiveResyncWithItsOffMainDiffWalksNoWorkspaceSnapshotOnMain(sessionSize: Int) async {
        let store = DaemonStore()
        store.apply(snapshot: session(sessionSize))
        let next = session(sessionSize, changing: 7)
        let memo = store.snapshotMemo
        let diff = await SnapshotDiff.computed(next, against: memo.applied, revision: memo.revision)
        let before = store.snapshotWorkspacesWalkedOnMain
        store.apply(snapshot: next, diff: diff)
        let walked = store.snapshotWorkspacesWalkedOnMain - before
        #expect(walked == 0, "main walked \(walked) workspace snapshots in a \(sessionSize)-workspace session")
        #expect(store.workspaces[7].screens.first?.panes.first?.tabs.first?.title == "renamed 0")
        // The memo vouches for the tree it applied: the same snapshot again differs nowhere.
        let again = await SnapshotDiff.computed(next, against: store.snapshotMemo.applied, revision: store.snapshotMemo.revision)
        #expect(again.changed.isEmpty)
        #expect(store.snapshotMemo.applied.count == sessionSize)
    }

    /// Review 1 of pl-main-bc: a snapshot that changes only the saved groups (a group saved or
    /// unsaved while its live group's own snapshot stays the same) left `isSaved` stale on the
    /// live group, because the incremental apply primed only the workspaces that changed.
    @Test func savingOrUnsavingAGroupInASnapshotThatChangesOnlyTheSavedGroupsMarksItsLiveGroup() throws {
        let store = DaemonStore()
        var workspaces = session(5).workspaces
        workspaces[2].screens[0].panes[0].tabGroups = [
            TabGroupSnapshot(id: "g", surfaces: [SurfaceID(rawValue: 2 * 100 + 10)], pane: PaneID(rawValue: 2 * 100 + 1)),
        ]
        store.apply(snapshot: DaemonTree(workspaces: workspaces))
        let group = try #require(store.index.tabGroupsByID["g"])
        #expect(!group.isSaved)
        store.apply(snapshot: DaemonTree(workspaces: workspaces, savedTabGroups: [SavedTabGroupSnapshot(id: "s", openGroup: "g")]))
        #expect(group.isSaved, "the saved record now names the open group")
        store.apply(snapshot: DaemonTree(workspaces: workspaces))
        #expect(!group.isSaved, "the saved record is gone")
    }
}

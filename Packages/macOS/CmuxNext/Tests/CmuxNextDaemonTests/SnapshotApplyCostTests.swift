@testable import CmuxNextDaemon
import Foundation
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
        #expect(store.workspaces[7].screens.first?.panes.first?.tabs.first?.titleText == "renamed 0")
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
        #expect(store.index.tabsBySurface[surface]?.titleText == "from an event")
        store.apply(snapshot: session(20))
        #expect(store.index.tabsBySurface[surface]?.titleText == "t 0")
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
        let stale = SnapshotDiff(revision: store.snapshotMemo.revision &- 1, changed: [:], removed: [], order: [], sameOrder: true)
        store.apply(snapshot: session(20, changing: 5), diff: stale)
        #expect(store.workspaces[5].screens.first?.panes.first?.tabs.first?.titleText == "renamed 0",
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
        let diff = await store.snapshotDiff(of: next)
        let before = store.snapshotWorkspacesWalkedOnMain
        store.apply(snapshot: next, diff: diff)
        let walked = store.snapshotWorkspacesWalkedOnMain - before
        #expect(walked == 0, "main walked \(walked) workspace snapshots in a \(sessionSize)-workspace session")
        #expect(store.workspaces[7].screens.first?.panes.first?.tabs.first?.titleText == "renamed 0")
        // The memo vouches for the tree it applied: the same snapshot again differs nowhere.
        let again = await store.snapshotDiff(of: next)
        #expect(again?.changed.isEmpty == true)
        #expect(again?.removed.isEmpty == true)
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

    /// Review 2 of pl-main-bc: agent statuses, agent presence and notifications write no field of
    /// the tree snapshot, and a title, size or exit writes one tab's. Each marked its whole workspace,
    /// so the next snapshot re-applied, re-indexed and re-laid every workspace an agent or a terminal
    /// title touched (STRESS: 10 agents ticking, 10 terminals retitling, 72 tabs in one workspace).
    @Test func eventsBetweenTwoIdenticalSnapshotsReapplyOnlyTheTabsTheyWrote() throws {
        let store = DaemonStore()
        store.apply(snapshot: session(50))
        for index in 0..<10 {
            let surface = SurfaceID(rawValue: UInt64(index * 100 + 10))
            _ = store.apply(.agentChanged(AgentStatus(surface: surface, state: .working, source: "hook", agent: "claude", updatedAtMs: 100)))
            _ = store.apply(.agentPresenceChanged(AgentPresence(surface: surface, activity: .editing, agent: "claude", path: "/r/a.rs")))
        }
        let json = #"{"notification":1,"title":"","body":"done","level":"info","surface":\#(20 * 100 + 10)}"#
        _ = store.apply(.notification(try JSONDecoder().decode(DaemonNotification.self, from: Data(json.utf8))))
        // Five tabs in five other workspaces retitled by events; the daemon's copy (the snapshot) still
        // has the old titles, so the snapshot corrects those tabs.
        let retitled = (30..<35).map { SurfaceID(rawValue: UInt64($0 * 100 + 11)) }
        for surface in retitled { _ = store.apply(.titleChanged(surface: surface, title: "from an event")) }
        let before = store.index.indexedRecords
        store.apply(snapshot: session(50))
        let indexed = store.index.indexedRecords - before
        #expect(indexed <= retitled.count, "the snapshot indexed \(indexed) records for 5 retitled tabs and 10 agents")
        for surface in retitled { #expect(store.index.tabsBySurface[surface]?.titleText == "t 1") }
        #expect(store.index.tabsBySurface[SurfaceID(rawValue: 10)]?.agent?.state == .working, "agent state is not the snapshot's")
        #expect(store.index.tabsBySurface[SurfaceID(rawValue: 10)]?.presence != nil)
    }

    /// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". A `tree-changed` that changed one
    /// workspace and moved none rebuilt the whole confirmed list on main (a dictionary of every workspace, the new
    /// list, a compare of both): O(session) per event. It now writes the touched records only.
    @Test(arguments: [100, 3000])
    func aSnapshotThatMovedNoWorkspaceWalksNoWorkspaceListOnMain(sessionSize: Int) async {
        let store = DaemonStore()
        store.apply(snapshot: session(sessionSize))
        for round in 0..<3 {
            let next = session(sessionSize, changing: 7 + round)
            let diff = await store.snapshotDiff(of: next)
            let before = store.workspaceListWalkedOnMain
            store.apply(snapshot: next, diff: diff)
            #expect(store.workspaceListWalkedOnMain - before == 0, "round \(round) walked the list of \(sessionSize) workspaces")
            #expect(store.workspaces[7 + round].screens.first?.panes.first?.tabs.first?.titleText == "renamed 0")
            #expect(store.workspaces.count == sessionSize)
        }
    }

    /// A list written since the last snapshot (a move event, an intent) is not the memo's: a snapshot in the memo's
    /// order puts it back, though it names no workspace as changed.
    @Test func aSnapshotInTheMemosOrderUndoesAListWriteTheDaemonDidNotKeep() async {
        let store = DaemonStore()
        let tree = session(5)
        store.apply(snapshot: tree)
        store.workspaces = store.workspaces.reversed()
        #expect(store.workspaces.first?.name == "w4")
        let diff = await store.snapshotDiff(of: tree)
        store.apply(snapshot: tree, diff: diff)
        #expect(store.workspaces.map(\.name) == tree.workspaces.map(\.name))
    }

    /// A workspace the daemon added and one it closed still apply through the list rebuild.
    @Test func aSnapshotThatAddsOrClosesAWorkspaceStillRebuildsTheList() async {
        let store = DaemonStore()
        store.apply(snapshot: session(5))
        let added = DaemonTree(workspaces: session(5).workspaces + [workspace(9)])
        store.apply(snapshot: added, diff: await store.snapshotDiff(of: added))
        #expect(store.workspaces.map(\.name) == added.workspaces.map(\.name))
        let closed = DaemonTree(workspaces: Array(added.workspaces.dropFirst()))
        store.apply(snapshot: closed, diff: await store.snapshotDiff(of: closed))
        #expect(store.workspaces.map(\.name) == closed.workspaces.map(\.name))
        #expect(store.index.workspacesByHandle[WorkspaceHandle(rawValue: 3)] == nil)
    }
}

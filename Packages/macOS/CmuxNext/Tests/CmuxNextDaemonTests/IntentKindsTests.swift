import Foundation
import Testing
@testable import CmuxNextDaemon

/// The intent kinds beyond tab moves (rename, pin, workspace order and
/// group, collapse) follow the same rule as moves: shown until settled by
/// echo, by the store reaching the reply's sequence, or by rejection.
@MainActor @Suite struct IntentKindsTests {
    private func loaded() throws -> (DaemonStore, DaemonTree) {
        let store = DaemonStore()
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        store.apply(snapshot: tree)
        return (store, tree)
    }

    /// The rename's reply came back (rename-tab echoes no transaction), but
    /// its `tab-changed` is not applied yet, and a resync that started
    /// before the reply lands with the old name. The rename is not settled,
    /// so it must stay visible; the legacy patch was dropped at "the next
    /// snapshot" and the old name showed until the event arrived.
    @Test func anUnsettledRenameSurvivesASnapshotThatPredatesIt() async throws {
        let (store, tree) = try loaded()
        store.intend(.renameTab(surface: 3, name: "renamed"), transaction: "tx")
        store.noteSettled("tx", at: 10)
        store.apply(snapshot: tree)
        #expect(store.tab(surface: 3)?.name == "renamed")
    }

    /// Four workspaces, two in group g1, so placement has a section to
    /// work in: daemon order a(g1) b c(g1) d.
    private func grouped() throws -> (DaemonStore, DaemonTree) {
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        let template = tree.workspaces[1]
        tree.workspaces = ["a", "b", "c", "d"].enumerated().map { index, name in
            var workspace = template
            workspace.id = WorkspaceHandle(rawValue: UInt64(40 + index))
            workspace.key = WorkspaceKey(rawValue: name)
            workspace.resourceID = nil
            workspace.name = name
            workspace.group = name == "a" || name == "c" ? "g1" : nil
            return workspace
        }
        tree.groups = [WorkspaceGroupSnapshot(id: "g1", name: "Group", index: 0)]
        let store = DaemonStore()
        store.apply(snapshot: tree)
        return (store, tree)
    }

    private func order(_ store: DaemonStore) -> [String] { store.workspaces.map(\.name) }

    /// A placement names a section index, so it is reapplied on top of
    /// another client's reorder with the daemon's rule, not as a stale
    /// absolute index.
    @Test func aPlacementIsReappliedOnTopOfAnotherClientsReorder() throws {
        let (store, tree) = try grouped()
        // b into g1 at section index 1 (between a and c): a b c d.
        store.intend(.placeWorkspace(key: "b", group: "g1", index: 1), transaction: "tx")
        #expect(order(store) == ["a", "b", "c", "d"])
        #expect(store.workspace(key: "b")?.group == "g1")
        // Another client moves d to the front: confirmed d a b c.
        var moved = tree.workspaces[3]
        moved.group = nil
        store.apply(.workspaceMoved(WorkspaceDelta(workspace: moved.id, index: 0, entity: moved, workspaceRevision: tree.workspaceRevision + 1)))
        // Before c (the g1 member at index 1 without b): d a b c.
        #expect(order(store) == ["d", "a", "b", "c"])
        #expect(store.sidebarSections.map { $0.workspaces.map(\.name) } == [["d"], ["a", "b", "c"]])
    }

    @Test func aRejectedReorderRestoresTheOrderAndTellsTheWindows() throws {
        let (store, _) = try grouped()
        var lists = 0
        store.onWorkspaceListChanged = { lists += 1 }
        store.intend(.moveWorkspace(key: "a", index: 3), transaction: "tx")
        #expect(order(store) == ["b", "c", "d", "a"])
        #expect(lists == 1)
        store.rejectIntent("tx")
        #expect(order(store) == ["a", "b", "c", "d"])
        #expect(lists == 2)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A collapse is reported only as `tree-changed`: the intent stays
    /// visible through the resync and leaves once the snapshot holding it
    /// is applied.
    @Test func aCollapseStaysShownThroughItsResync() throws {
        let (store, tree) = try grouped()
        store.intend(.setWorkspaceGroupCollapsed("g1", collapsed: true), transaction: "tx")
        #expect(store.group("g1")?.collapsed == true)
        store.noteSettled("tx", at: 1)
        #expect(store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil))]) == .resync)
        #expect(store.group("g1")?.collapsed == true)
        store.apply(snapshot: tree) // started before the command
        #expect(store.group("g1")?.collapsed == true)
        var collapsed = tree
        collapsed.groups[0].collapsed = true
        store.apply(snapshot: collapsed)
        store.advanceAppliedSequence(to: 1)
        #expect(!store.hasPendingIntents)
        #expect(store.group("g1")?.collapsed == true)
        #expect(store.mirrorViolations.isEmpty)
    }

    @Test func pinAndTabGroupCollapseShowAndRevert() throws {
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        tree.workspaces[0].screens[0].panes[0].tabGroups = [TabGroupSnapshot(id: "tg", name: "API", surfaces: [3, 13])]
        let store = DaemonStore()
        store.apply(snapshot: tree)
        store.intend(.setTabPinned(surface: 13, pinned: true), transaction: "pin")
        store.intend(.setTabGroupCollapsed("tg", collapsed: true), transaction: "fold")
        #expect(store.tab(surface: 13)?.pinned == true)
        #expect(store.tabGroup("tg")?.collapsed == true)
        // A daemon event for the same tab applies under the lifted overlay.
        store.apply(.titleChanged(surface: 13, title: "vim"))
        #expect(store.tab(surface: 13)?.pinned == true)
        store.rejectIntent("pin")
        store.rejectIntent("fold")
        #expect(store.tab(surface: 13)?.pinned == false)
        #expect(store.tab(surface: 13)?.title == "vim")
        #expect(store.tabGroup("tg")?.collapsed == false)
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A write that bypasses the daemon apply and the overlay (here a name)
    /// is reported in debug builds, now that names, pins, groups and
    /// collapse are part of the checked mirror.
    @Test func aDirectNameWriteIsAMirrorViolation() throws {
        let (store, _) = try loaded()
        store.intend(.renameTab(surface: 3, name: "mine"), transaction: "tx")
        store.tab(surface: 13)?.setName("sneaky")
        store.rejectIntent("tx")
        #if DEBUG
        #expect(store.mirrorViolations.count == 1)
        #endif
    }

    /// The reply came after the connection ended (no event sequence to
    /// wait for): the intent stays shown until the next snapshot applies.
    @Test func aReplyWithoutASequenceSettlesAtTheNextSnapshot() throws {
        let (store, tree) = try loaded()
        store.intend(.setTabPinned(surface: 3, pinned: true), transaction: "tx")
        store.noteSettledAtNextSnapshot("tx")
        store.advanceAppliedSequence(to: 50)
        #expect(store.tab(surface: 3)?.pinned == true)
        var pinned = tree
        pinned.workspaces[0].screens[0].panes[0].tabs[0].pinned = true
        store.apply(snapshot: pinned)
        #expect(!store.hasPendingIntents)
        #expect(store.tab(surface: 3)?.pinned == true)
    }

    /// An empty name clears the custom name (the daemon stores null), and
    /// a placement into a group the mirror does not know changes nothing.
    @Test func emptyNamesClearAndUnknownGroupsAreSkipped() throws {
        let (store, _) = try grouped()
        store.intend(.renameWorkspace(key: "a", name: "kept"), transaction: "keep")
        store.intend(.placeWorkspace(key: "b", group: "nope", index: 0), transaction: "nope")
        store.intend(.setWorkspaceGroup(key: "d", group: "nope"), transaction: "nope2")
        #expect(order(store) == ["kept", "b", "c", "d"])
        #expect(store.workspace(key: "b")?.group == nil)
        #expect(store.workspace(key: "d")?.group == nil)

        let (tabs, _) = try loaded()
        #expect(tabs.tab(surface: 3)?.name == "main")
        tabs.intend(.renameTab(surface: 3, name: ""), transaction: "clear")
        #expect(tabs.tab(surface: 3)?.name == nil)
    }
}

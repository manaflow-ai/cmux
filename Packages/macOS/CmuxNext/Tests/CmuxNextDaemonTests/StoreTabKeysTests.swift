@testable import CmuxNextDaemon
import Testing

/// The store's tab keys (p06-scheduler-051): the index reports a key when its first tab record is
/// indexed and when its last is dropped, never for a move inside the store, and a full snapshot
/// reports only the keys it added or removed. The index of tabs across machines keeps itself by these.
@MainActor @Suite struct StoreTabKeysTests {
    private static let handle: WorkspaceHandle = 1
    private static let screen: ScreenID = 100
    private static let pane: PaneID = 10
    private static let otherPane: PaneID = 20

    /// Workspace 1 with two panes: `tabs` in pane 10, nothing in pane 20.
    private static func tree(_ tabs: [TabSnapshot], revision: UInt64 = 1) -> DaemonTree {
        let panes = [PaneSnapshot(id: pane, tabs: tabs), PaneSnapshot(id: otherPane, tabs: [])]
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(pane), b: .leaf(otherPane))
        let screens = [ScreenSnapshot(id: screen, layout: layout, panes: panes)]
        return DaemonTree(workspaceRevision: revision, workspaces: [WorkspaceSnapshot(id: handle, key: nil, name: "w1", screens: screens)])
    }

    /// A store whose key changes are recorded in `changes`.
    @MainActor private final class Recorder {
        var changes: [(String, StoreTabKeys.Change)] = []
    }

    private func recording(_ store: DaemonStore) -> Recorder {
        let recorder = Recorder()
        store.tabKeys.onChange = { key, change in recorder.changes.append((key, change)) }
        return recorder
    }

    private func delta(_ tab: TabSnapshot, pane: PaneID = Self.pane, index: Int? = nil) -> TabDelta {
        TabDelta(workspace: Self.handle, screen: Self.screen, pane: pane, surface: tab.surface, index: index, entity: tab)
    }

    @Test func aTabAddedAndClosedListsAndDropsItsIDAndResource() throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree([TabSnapshot(surface: 1)]))
        let recorder = recording(store)
        let tab = TabSnapshot(surface: 2, tabResourceID: "tab_two")

        _ = store.apply(.tabAdded(delta(tab)))
        #expect(recorder.changes.map(\.1) == [.listed])
        #expect(recorder.changes.map(\.0) == ["tab_two"], "a tab whose id is its resource id lists one key")
        #expect(store.tabKeys.lists("tab_two"))

        recorder.changes.removeAll()
        _ = store.apply(.tabClosed(delta(tab)))
        #expect(recorder.changes.map(\.0) == ["tab_two"])
        #expect(recorder.changes.map(\.1) == [.dropped])
        #expect(!store.tabKeys.lists("tab_two"))
        #expect(store.tabKeys.lists("surface:1"))
    }

    @Test func aMoveBetweenPanesReportsNothing() throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree([TabSnapshot(surface: 1, tabResourceID: "tab_one")]))
        let recorder = recording(store)

        // tab-drag-v1: the moved tab's tab-changed names its new pane (drop and re-key in one apply).
        _ = store.apply(.tabChanged(delta(TabSnapshot(surface: 1, tabResourceID: "tab_one"), pane: Self.otherPane, index: 0)))
        #expect(store.pane(containing: 1)?.handle == Self.otherPane)
        #expect(recorder.changes.isEmpty, "a move kept the key listed: \(recorder.changes)")
        #expect(store.tabKeys.lists("tab_one"))
    }

    @Test func aSnapshotLeavesTheKeysItKeptAndReportsTheOnesItChanged() throws {
        let store = DaemonStore()
        let kept = (1...1_000).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0))) }
        store.apply(snapshot: Self.tree(kept + [TabSnapshot(surface: 5_000, tabResourceID: "tab_gone")]))
        let recorder = recording(store)

        store.apply(snapshot: Self.tree(kept + [TabSnapshot(surface: 6_000, tabResourceID: "tab_new")], revision: 2))
        // The net state of each reported key: a workspace indexed again may drop and list its keys.
        var net: [String: StoreTabKeys.Change] = [:]
        for (key, change) in recorder.changes { net[key] = change }
        #expect(net["tab_gone"] == .dropped)
        #expect(net["tab_new"] == .listed)
        #expect(net.filter { $0.value == .dropped }.count == 1, "only tab_gone left")
        #expect(store.tabKeys.listed.count == 1_001)
        #expect(!store.tabKeys.lists("tab_gone") && store.tabKeys.lists("tab_new"))
    }

    /// A full rebuild indexes every record again without dropping them one by one: it reports nothing
    /// for the keys it kept.
    @Test func aRebuildReportsOnlyTheKeysItAddedOrRemoved() throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree((1...1_000).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0))) }))
        let recorder = recording(store)

        store.rebuildIndex()
        #expect(recorder.changes.isEmpty, "a rebuild of the same tree reported \(recorder.changes.count) keys")
        #expect(store.tabKeys.listed.count == 1_000)
    }
}

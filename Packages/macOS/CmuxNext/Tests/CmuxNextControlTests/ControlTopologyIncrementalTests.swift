@testable import CmuxNextControl
import CmuxNextDaemon
import Testing

/// The control snapshot publish maps only the workspaces that changed, or
/// whose app facts a window or page tab can set, and still lists exactly
/// what a full build lists (sidebar churn bench, 400 workspaces: every
/// publish visited every workspace on the main actor).
@MainActor
struct ControlTopologyIncrementalTests {
    private static let count: UInt64 = 200

    private static func tree(_ ids: [UInt64]) -> DaemonTree {
        DaemonTree(workspaces: ids.map { id in
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [TabSnapshot(surface: SurfaceID(rawValue: id))])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(id)", screens: [screen])
        })
    }

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "boot"), generationChanged: true))
        store.apply(snapshot: tree(Array(1...count)))
        return store
    }

    /// A pane's shown tab, as a window would report it for the panes of `shown`.
    private static func selectedTab(in shown: [WorkspaceModel]) -> (PaneModel) -> String? {
        let panes = Set(shown.flatMap { $0.screens.flatMap(\.panes) }.map(ObjectIdentifier.init))
        return { pane in panes.contains(ObjectIdentifier(pane)) ? pane.tabs.first?.id : nil }
    }

    private static func topology(_ store: DaemonStore, cache: ControlWorkspaceInfoCache?,
                                 shown: [WorkspaceModel] = []) -> ControlTopology {
        ControlTopology(store: store, selectedTab: selectedTab(in: shown), cache: cache,
                        scope: cache == nil ? nil : ControlAppFactScope(shown: shown))
    }

    @Test func aPublishWithNothingChangedVisitsNoWorkspace() {
        let store = Self.store()
        let cache = ControlWorkspaceInfoCache()
        _ = Self.topology(store, cache: cache)
        let before = cache.workspaceVisits
        let topology = Self.topology(store, cache: cache)
        #expect(cache.workspaceVisits - before == 0)
        #expect(topology == Self.topology(store, cache: nil))
    }

    @Test func oneTabChangeVisitsOneWorkspace() {
        let store = Self.store()
        let cache = ControlWorkspaceInfoCache()
        _ = Self.topology(store, cache: cache)
        let before = cache.workspaceVisits
        store.apply(.titleChanged(surface: 7, title: "changed"))
        let topology = Self.topology(store, cache: cache)
        #expect(cache.workspaceVisits - before == 1)
        #expect(topology == Self.topology(store, cache: nil))
        #expect(topology.workspaces.flatMap(\.panes).flatMap(\.tabs).contains { $0.title == "changed" })
    }

    /// A shown workspace's panes report their shown tab; once the window
    /// shows another workspace, the first one's panes report none again.
    @Test func theShownWorkspaceCarriesItsAppFactsAndDropsThemWhenHidden() {
        let store = Self.store()
        let cache = ControlWorkspaceInfoCache()
        let first = [store.workspaces[4]], second = [store.workspaces[9]]
        let shownFirst = Self.topology(store, cache: cache, shown: first)
        #expect(shownFirst == Self.topology(store, cache: nil, shown: first))
        #expect(shownFirst.workspaces[4].panes.first?.selectedTabID != nil)
        let before = cache.workspaceVisits
        let shownSecond = Self.topology(store, cache: cache, shown: second)
        #expect(shownSecond == Self.topology(store, cache: nil, shown: second))
        #expect(shownSecond.workspaces[4].panes.first?.selectedTabID == nil)
        #expect(shownSecond.workspaces[9].panes.first?.selectedTabID != nil)
        #expect(cache.workspaceVisits - before <= 2)
    }

    /// Workspaces added, closed and reordered: the list follows the store.
    @Test func aListChangeListsWhatAFullBuildLists() {
        let store = Self.store()
        let cache = ControlWorkspaceInfoCache()
        _ = Self.topology(store, cache: cache)
        var ids = Array(1...Self.count).filter { $0 != 3 }
        ids.swapAt(0, 10)
        ids.append(Self.count + 1)
        store.apply(snapshot: Self.tree(ids))
        let topology = Self.topology(store, cache: cache)
        #expect(topology == Self.topology(store, cache: nil))
        #expect(topology.workspaces.count == ids.count)
        store.apply(.titleChanged(surface: SurfaceID(rawValue: Self.count + 1), title: "new"))
        #expect(Self.topology(store, cache: cache) == Self.topology(store, cache: nil))
    }

    /// The kept tab count equals a full walk of the published topology, through a tab change,
    /// a list change and a new workspace's tab.
    @Test func theKeptTabCountMatchesTheTopology() {
        let store = Self.store()
        let cache = ControlWorkspaceInfoCache()
        #expect(cache.tabCount == 0)
        #expect(Self.topology(store, cache: cache).tabCount == cache.tabCount)
        #expect(cache.tabCount == Int(Self.count))
        store.apply(.titleChanged(surface: 7, title: "changed"))
        #expect(Self.topology(store, cache: cache).tabCount == cache.tabCount)
        var ids = Array(1...Self.count).filter { $0 != 3 }
        ids.append(Self.count + 1)
        store.apply(snapshot: Self.tree(ids))
        #expect(Self.topology(store, cache: cache).tabCount == cache.tabCount)
        #expect(cache.tabCount == ids.count)
    }
}

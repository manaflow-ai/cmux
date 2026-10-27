@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Testing

/// p06-scheduler-302 (R-wait): a new tab's move into its slot, and a split's New Tab page's move to
/// its new pane, wait for the store to list the tab with the store's keyed waits (StoreWaiters), not
/// an `ObservationStream` predicate that read every pane's tabs on each tab-list change.
@MainActor @Suite(.timeLimit(.minutes(1))) struct NewTabSlotListedWaitTests {
    private static let never: Duration = .seconds(3_600)

    private func store() -> DaemonStore {
        let store = DaemonStore()
        let panes = [PaneSnapshot(id: 10, tabs: [TabSnapshot(surface: 1)])]
        let screens = [ScreenSnapshot(id: 100, layout: .leaf(10), panes: panes)]
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: screens)]))
        return store
    }

    private func add(_ tab: TabSnapshot, to store: DaemonStore) {
        _ = store.apply(.tabAdded(TabDelta(workspace: 1, screen: 100, pane: 10, surface: tab.surface, index: nil, entity: tab)))
    }

    @Test func aTabNamedByItsResourceIDResumesInTheApplyThatListsIt() async throws {
        let store = store()
        let wait = Task { await NewTabSlot.listed("tab_new", in: store, limit: Self.never) }
        await store.waiters.untilPending(2)
        let before = store.waiters.evaluations
        for surface in 2..<200 { add(TabSnapshot(surface: SurfaceID(rawValue: UInt64(surface))), to: store) }
        #expect(store.waiters.evaluations == before, "other tabs' inserts read the wait's condition")
        add(TabSnapshot(surface: 500, tabResourceID: "tab_new"), to: store)
        let tab = try #require(await wait.value, "the wait did not resume with the listed tab")
        #expect(tab === store.tab(surface: 500))
        #expect(store.waiters.pendingCount == 0, "the other key's waiter outlived the found tab")
    }

    @Test func aListedTabReturnsAtOnce() async {
        let store = store()
        add(TabSnapshot(surface: 7, tabResourceID: "tab_listed"), to: store)
        let tab = await NewTabSlot.listed("tab_listed", in: store, limit: Self.never)
        #expect(tab === store.tab(surface: 7))
        #expect(store.waiters.pendingCount == 0)
    }

    @Test func aCancelledWaitLeavesNoWaiter() async {
        let store = store()
        let wait = Task { await NewTabSlot.listed("tab_never", in: store, limit: Self.never) }
        await store.waiters.untilPending(2)
        wait.cancel()
        #expect(await wait.value == nil)
        #expect(store.waiters.pendingCount == 0, "a cancelled wait left a waiter on the store")
    }
}

@testable import CmuxNextDaemon
import CmuxNextWakeupsTestSupport
import Testing

/// Keyed waits on the store (p06-scheduler-027): a waiter for one record reads its condition only
/// when that record's key changes, resumes in the apply that lists (or drops) it, and resumes with
/// nil on its timeout or when its task is cancelled.
@MainActor @Suite struct StoreWaitersTests {
    private static let handle: WorkspaceHandle = 1
    private static let screen: ScreenID = 100
    private static let pane: PaneID = 10
    private static let otherPane: PaneID = 20

    /// Workspace 1 with two panes: tab 1 in pane 10, tab 2 in pane 20.
    private static func tree() -> DaemonTree {
        let panes = [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: 1)]), PaneSnapshot(id: otherPane, tabs: [TabSnapshot(surface: 2)])]
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(pane), b: .leaf(otherPane))
        let screens = [ScreenSnapshot(id: screen, layout: layout, panes: panes)]
        return DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(id: handle, key: nil, name: "w1", screens: screens)])
    }

    private func loadedStore() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree())
        return store
    }

    private func add(_ tab: TabSnapshot, to store: DaemonStore) {
        _ = store.apply(.tabAdded(TabDelta(workspace: Self.handle, screen: Self.screen, pane: Self.pane, surface: tab.surface, index: nil,
                                           entity: tab)))
    }

    /// Lets the waiting tasks run to their suspension (they start on this actor once it yields).
    private func registered(_ count: Int, in store: DaemonStore, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<1_000 where store.waiters.pendingCount < count { await Task.yield() }
        try #require(store.waiters.pendingCount == count, "waiters registered", sourceLocation: sourceLocation)
    }

    @Test func aTabWaiterReadsNothingOnAThousandOtherInsertsAndResumesInItsApply() async throws {
        let store = loadedStore()
        let bySurface = Task { await store.waitForTab(surface: 5_000, timeout: nil) }
        let byID = Task { await store.waitForTab(id: "tab_target", timeout: nil) }
        let byResource = Task { await store.waitForTab(resource: "tab_target", timeout: nil) }
        try await registered(3, in: store)
        let before = store.waiters.evaluations

        for surface in 2_000..<3_000 { add(TabSnapshot(surface: SurfaceID(rawValue: UInt64(surface))), to: store) }
        #expect(store.waiters.evaluations == before, "1000 other inserts read \(store.waiters.evaluations - before) waiter conditions")
        #expect(store.waiters.pendingCount == 3)

        add(TabSnapshot(surface: 5_000, tabResourceID: "tab_target"), to: store)
        #expect(store.waiters.pendingCount == 0, "the tab's own apply resumed its waiters")
        #expect(store.waiters.evaluations - before == 3, "one read per waiter of the tab's keys")
        let tab = try #require(store.tab(surface: 5_000))
        #expect(await bySurface.value === tab)
        #expect(await byID.value === tab)
        #expect(await byResource.value === tab)
    }

    @Test func aListedTabReturnsAtOnce() async {
        let store = loadedStore()
        let tab = await store.waitForTab(surface: 1, timeout: nil)
        #expect(tab === store.tab(surface: 1))
        #expect(store.waiters.pendingCount == 0)
    }

    @Test func aWorkspaceWaiterResumesWhenItsWorkspaceIsAdded() async throws {
        let store = loadedStore()
        let byID = Task { await store.waitForWorkspace(id: "handle:7", timeout: nil) }
        let byResource = Task { await store.waitForWorkspace(resource: "ws_7", timeout: nil) }
        try await registered(2, in: store)
        let before = store.waiters.evaluations
        add(TabSnapshot(surface: 9), to: store)
        #expect(store.waiters.evaluations == before, "a tab insert read a workspace waiter")

        let pane = PaneSnapshot(id: 70, tabs: [TabSnapshot(surface: 71)])
        let screen = ScreenSnapshot(id: 700, layout: .leaf(70), panes: [pane])
        let workspace = WorkspaceSnapshot(id: 7, key: nil, resourceID: "ws_7", name: "w7", screens: [screen])
        _ = store.apply(.workspaceAdded(WorkspaceDelta(workspace: 7, index: 1, entity: workspace, workspaceRevision: 2)))
        #expect(store.waiters.pendingCount == 0)
        let added = try #require(store.workspace(handle: 7))
        #expect(await byID.value === added)
        #expect(await byResource.value === added)
    }

    @Test func waitLoadedResumesWithTheFirstSnapshot() async throws {
        let store = DaemonStore()
        let loaded = Task { await store.waitLoaded(timeout: nil) }
        try await registered(1, in: store)
        store.apply(snapshot: Self.tree())
        #expect(store.waiters.pendingCount == 0)
        #expect(await loaded.value)
        #expect(await store.waitLoaded(timeout: nil), "a loaded store returns at once")
    }

    @Test func waitConnectionResumesOnlyForAMatchingState() async throws {
        let store = loadedStore()
        let failed = Task {
            await store.waitConnection(timeout: nil) { state in
                if case .failed = state { return true }
                return false
            }
        }
        try await registered(1, in: store)
        _ = DaemonConnectionChange.disconnected("socket closed").apply(to: store)
        #expect(store.waiters.pendingCount == 1, "a disconnect does not match")
        store.markFailed("incompatible daemon")
        #expect(store.waiters.pendingCount == 0)
        #expect(await failed.value == .failed("incompatible daemon"))
    }

    @Test func aMovedTabIsNotGoneAndAClosedOneIs() async throws {
        let store = loadedStore()
        let tab = try #require(store.tab(surface: 1))
        let bySurface = Task { await store.waitTabGone(surface: 1, timeout: nil) }
        let byID = Task { await store.waitTabGone(id: tab.id, timeout: nil) }
        try await registered(2, in: store)

        // tab-drag-v1: the moved tab's tab-changed names its new pane (drop and re-key in one apply).
        _ = store.apply(.tabChanged(TabDelta(workspace: Self.handle, screen: Self.screen, pane: Self.otherPane, surface: 1, index: 1,
                                             entity: TabSnapshot(surface: 1))))
        #expect(store.pane(containing: 1)?.handle == Self.otherPane)
        #expect(store.waiters.pendingCount == 2, "a move left the tab listed")

        _ = store.apply(.tabClosed(TabDelta(workspace: Self.handle, screen: Self.screen, pane: Self.otherPane, surface: 1, index: nil,
                                            entity: TabSnapshot(surface: 1))))
        #expect(store.waiters.pendingCount == 0)
        #expect(await bySurface.value)
        #expect(await byID.value)
    }

    @Test func aSnapshotThatDropsATabResumesItsGoneWaiter() async throws {
        let store = loadedStore()
        let gone = Task { await store.waitTabGone(surface: 2, timeout: nil) }
        try await registered(1, in: store)
        let pane = PaneSnapshot(id: Self.pane, tabs: [TabSnapshot(surface: 1)])
        let screen = ScreenSnapshot(id: Self.screen, layout: .leaf(Self.pane), panes: [pane])
        let workspace = WorkspaceSnapshot(id: Self.handle, key: nil, name: "w1", screens: [screen])
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [workspace]))
        #expect(await gone.value)
        #expect(store.waiters.pendingCount == 0)
    }

    @Test func aTimeoutResumesWithNil() async throws {
        let store = loadedStore()
        let clock = ManualClock()
        let waiter = Task { await store.waitForTab(surface: 404, timeout: .seconds(2), clock: clock) }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        #expect(store.waiters.pendingCount == 1)
        clock.advance(by: .seconds(1))
        #expect(await waiter.value == nil)
        #expect(store.waiters.pendingCount == 0)
        // A tab listed after the timeout resumes nothing.
        add(TabSnapshot(surface: 404), to: store)
        #expect(store.tab(surface: 404) != nil)
    }

    @Test func aResumedWaiterCancelsItsTimer() async throws {
        let store = loadedStore()
        let clock = ManualClock()
        let waiter = Task { await store.waitForTab(surface: 405, timeout: .seconds(2), clock: clock) }
        try await clock.waitForSleeper()
        add(TabSnapshot(surface: 405), to: store)
        #expect(await waiter.value === store.tab(surface: 405))
        #expect(clock.sleeperCount == 0, "the resume cancelled the deadline's sleep")
        clock.advance(by: .seconds(2))
        #expect(store.waiters.pendingCount == 0)
    }

    @Test func cancellingTheWaitingTaskResumesWithNil() async throws {
        let store = loadedStore()
        let waiter = Task { await store.waitForWorkspace(id: "handle:404", timeout: nil) }
        try await registered(1, in: store)
        waiter.cancel()
        #expect(await waiter.value == nil)
        #expect(store.waiters.pendingCount == 0)

        // Cancelled before it runs: it returns nil without filing a waiter.
        let cancelled = Task { await store.waitForTab(surface: 404, timeout: nil) }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(store.waiters.pendingCount == 0)
    }
}

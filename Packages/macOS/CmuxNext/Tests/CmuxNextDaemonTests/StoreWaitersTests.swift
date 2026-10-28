import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextWakeups
import Testing

/// Keyed waits on the store: a waiter for one record reads its condition only
/// when that record's key changes, resumes in the apply that lists (or drops) it, and resumes with
/// nil on its timeout or when its task is cancelled. The timeouts are entries on the store's
/// MainWakeUpQueue; the test moves its uptime and fires it.
@MainActor @Suite(.timeLimit(.minutes(1))) struct StoreWaitersTests {
    private static let handle: WorkspaceHandle = 1
    private static let screen: ScreenID = 100
    private static let pane: PaneID = 10
    private static let otherPane: PaneID = 20
    /// A timeout no test reaches (the rig's uptime moves only when a test advances it).
    private static let never: Duration = .seconds(3_600)

    /// Workspace 1 with two panes: tab 1 in pane 10, tab 2 in pane 20.
    private static func tree() -> DaemonTree {
        let panes = [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: 1)]), PaneSnapshot(id: otherPane, tabs: [TabSnapshot(surface: 2)])]
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(pane), b: .leaf(otherPane))
        let screens = [ScreenSnapshot(id: screen, layout: layout, panes: panes)]
        return DaemonTree(workspaceRevision: 1, workspaces: [WorkspaceSnapshot(id: handle, key: nil, name: "w1", screens: screens)])
    }

    private func loadedStore(_ rig: DeadlineRig? = nil) -> DaemonStore {
        let store = DaemonStore(waitDeadlines: (rig ?? DeadlineRig()).queue)
        store.apply(snapshot: Self.tree())
        return store
    }

    private func add(_ tab: TabSnapshot, to store: DaemonStore) {
        _ = store.apply(.tabAdded(TabDelta(workspace: Self.handle, screen: Self.screen, pane: Self.pane, surface: tab.surface, index: nil,
                                           entity: tab)))
    }

    @Test func aTabWaiterReadsNothingOnAThousandOtherInsertsAndResumesInItsApply() async throws {
        let store = loadedStore()
        let bySurface = Task { await store.waitForTab(surface: 5_000, timeout: Self.never) }
        let byID = Task { await store.waitForTab(id: "tab_target", timeout: Self.never) }
        let byResource = Task { await store.waitForTab(resource: "tab_target", timeout: Self.never) }
        await store.waiters.untilPending(3)
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

    @Test func aTabAnIntentShowsResumesItsWaitersInTheIntentsTurn() async throws {
        let rig = DeadlineRig()
        let store = loadedStore(rig)
        let provisional = ProvisionalTab()
        let bySurface = Task { await store.waitForTab(surface: provisional.surface, timeout: Self.never) }
        let byID = Task { await store.waitForTab(id: provisional.id, timeout: Self.never) }
        await store.waiters.untilPending(2)
        let before = store.waiters.evaluations

        store.intend(.renameTab(surface: 1, name: "renamed"), transaction: .generate())
        #expect(store.waiters.evaluations == before, "an intent on another tab read a waiter condition")

        let snapshot = provisional.conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", hostName: nil)))
        store.intend(.createTab(pane: Self.pane, provisional: snapshot), transaction: .generate())
        #expect(store.waiters.pendingCount == 0, "the intend turn resumed the tab's waiters")
        #expect(store.waiters.evaluations - before == 2)
        let tab = try #require(store.tab(surface: provisional.surface))
        #expect(await bySurface.value === tab)
        #expect(await byID.value === tab)
        #expect(rig.queue.count == 0, "the resumes cancelled their timeouts")
    }

    @Test func aListedTabReturnsAtOnce() async {
        let store = loadedStore()
        let tab = await store.waitForTab(surface: 1, timeout: Self.never)
        #expect(tab === store.tab(surface: 1))
        #expect(store.waiters.pendingCount == 0)
    }

    @Test func aWorkspaceWaiterResumesWhenItsWorkspaceIsAdded() async throws {
        let store = loadedStore()
        let byID = Task { await store.waitForWorkspace(id: "handle:7", timeout: Self.never) }
        let byResource = Task { await store.waitForWorkspace(resource: "ws_7", timeout: Self.never) }
        await store.waiters.untilPending(2)
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
        let store = DaemonStore(waitDeadlines: DeadlineRig().queue)
        let loaded = Task { await store.waitLoaded(timeout: Self.never) }
        await store.waiters.untilPending(1)
        store.apply(snapshot: Self.tree())
        #expect(store.waiters.pendingCount == 0)
        #expect(await loaded.value)
        #expect(await store.waitLoaded(timeout: Self.never), "a loaded store returns at once")
    }

    @Test func waitConnectionResumesOnlyForAMatchingState() async throws {
        let store = loadedStore()
        let failed = Task {
            await store.waitConnection(timeout: Self.never) { state in
                if case .failed = state { return true }
                return false
            }
        }
        await store.waiters.untilPending(1)
        _ = DaemonConnectionChange.disconnected("socket closed").apply(to: store)
        #expect(store.waiters.pendingCount == 1, "a disconnect does not match")
        store.markFailed("incompatible daemon")
        #expect(store.waiters.pendingCount == 0)
        #expect(await failed.value == .failed("incompatible daemon"))
    }

    @Test func aMovedTabIsNotGoneAndAClosedOneIs() async throws {
        let store = loadedStore()
        let tab = try #require(store.tab(surface: 1))
        let bySurface = Task { await store.waitTabGone(surface: 1, timeout: Self.never) }
        let byID = Task { await store.waitTabGone(id: tab.id, timeout: Self.never) }
        await store.waiters.untilPending(2)

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
        let gone = Task { await store.waitTabGone(surface: 2, timeout: Self.never) }
        await store.waiters.untilPending(1)
        let pane = PaneSnapshot(id: Self.pane, tabs: [TabSnapshot(surface: 1)])
        let screen = ScreenSnapshot(id: Self.screen, layout: .leaf(Self.pane), panes: [pane])
        let workspace = WorkspaceSnapshot(id: Self.handle, key: nil, name: "w1", screens: [screen])
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [workspace]))
        #expect(await gone.value)
        #expect(store.waiters.pendingCount == 0)
    }

    @Test func aTimeoutResumesWithNilAndALaterInsertReadsNothing() async throws {
        let rig = DeadlineRig()
        let store = loadedStore(rig)
        let waiter = Task { await store.waitForTab(surface: 404, timeout: .seconds(2)) }
        await store.waiters.untilPending(1)
        rig.advance(by: .seconds(1))
        #expect(store.waiters.pendingCount == 1, "not due before its timeout")
        rig.advance(by: .seconds(1))
        #expect(store.waiters.pendingCount == 0)
        #expect(await waiter.value == nil)

        let before = store.waiters.evaluations
        add(TabSnapshot(surface: 404), to: store)
        #expect(store.tab(surface: 404) != nil)
        #expect(store.waiters.evaluations == before, "a tab listed after the timeout read no waiter")
    }

    /// The waiting task holds the store, so an owner that lets go of it (a torn-down service, a test
    /// store out of scope) cannot strand the wait: its timeout still resumes it.
    @Test func aWaitOnAStoreItsOwnerDroppedStillTimesOut() async throws {
        let rig = DeadlineRig()
        var store: DaemonStore? = loadedStore(rig)
        let waiter = Task { [store] in await store?.waitForTab(surface: 404, timeout: .seconds(1)) }
        await store?.waiters.untilPending(1)
        store = nil
        rig.advance(by: .seconds(1))
        #expect(await waiter.value == nil)
        #expect(rig.queue.count == 0)
    }

    @Test func theBoolAndConnectionWaitsTimeOut() async throws {
        let rig = DeadlineRig()
        let unloaded = DaemonStore(waitDeadlines: rig.queue)
        let store = loadedStore(rig)
        let loaded = Task { await unloaded.waitLoaded(timeout: .seconds(1)) }
        let gone = Task { await store.waitTabGone(surface: 1, timeout: .seconds(1)) }
        let id = try #require(store.tab(surface: 2)).id
        let goneByID = Task { await store.waitTabGone(id: id, timeout: .seconds(1)) }
        let failed = Task {
            await store.waitConnection(timeout: .seconds(1)) { state in
                if case .failed = state { return true }
                return false
            }
        }
        await unloaded.waiters.untilPending(1)
        await store.waiters.untilPending(3)
        #expect(rig.queue.count == 4, "the four timeouts share the store's one deadline queue")

        rig.advance(by: .seconds(1))
        #expect(await loaded.value == false)
        #expect(await gone.value == false)
        #expect(await goneByID.value == false)
        #expect(await failed.value == nil)
        #expect(unloaded.waiters.pendingCount == 0)
        #expect(store.waiters.pendingCount == 0)
    }

    @Test func aResumedWaiterCancelsItsTimeout() async throws {
        let rig = DeadlineRig()
        let store = loadedStore(rig)
        let waiter = Task { await store.waitForTab(surface: 405, timeout: .seconds(2)) }
        await store.waiters.untilPending(1)
        #expect(rig.queue.count == 1)
        add(TabSnapshot(surface: 405), to: store)
        #expect(await waiter.value === store.tab(surface: 405))
        #expect(rig.queue.count == 0, "the resume cancelled its deadline")
        rig.advance(by: .seconds(2))
        #expect(store.waiters.pendingCount == 0)
    }

    @Test func cancellingTheWaitingTaskResumesWithNil() async throws {
        let rig = DeadlineRig()
        let store = loadedStore(rig)
        let waiter = Task { await store.waitForWorkspace(id: "handle:404", timeout: Self.never) }
        await store.waiters.untilPending(1)
        waiter.cancel()
        #expect(await waiter.value == nil)
        #expect(store.waiters.pendingCount == 0)
        #expect(rig.queue.count == 0, "the cancel dropped its deadline")

        // Cancelled before it runs: it returns nil without filing a waiter.
        let cancelled = Task { await store.waitForTab(surface: 404, timeout: Self.never) }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(store.waiters.pendingCount == 0)
    }
}

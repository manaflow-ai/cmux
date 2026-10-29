@testable import CmuxNextDaemon
import CmuxNextCompat
import CmuxNextWakeups
import Testing

/// A drain of the event inbox costs what changed: the workspace-list check and
/// the unread sum cost the workspaces that joined, left or changed their own count, and the sidebar
/// is flattened (O(workspaces), once) only by a batch that changed the order, the membership or a
/// group. A storm of title events in hidden workspaces flattens no sidebar, with or without a
/// pending intent; a batch of moves joins the moved workspaces only. ``DrainCost`` counts each
/// drain in a histogram, which `debug.drain_cost` reports.
@MainActor @Suite struct DrainCostTests {
    private static let workspaces = 50
    private static let tabsPerWorkspace = 20
    private static let group = WorkspaceGroupID(rawValue: "group-a")

    private static func surface(_ workspace: Int, _ tab: Int) -> SurfaceID { SurfaceID(rawValue: UInt64(workspace * 100 + 10 + tab)) }
    private static func pane(_ workspace: Int) -> PaneID { PaneID(rawValue: UInt64(workspace * 100 + 1)) }
    private static func screen(_ workspace: Int) -> ScreenID { ScreenID(rawValue: UInt64(workspace * 100 + 2)) }
    private static func handle(_ workspace: Int) -> WorkspaceHandle { WorkspaceHandle(rawValue: UInt64(workspace * 100 + 3)) }

    /// Workspace `index` of `tabs` tabs; its first tab has an unread notification when `unread`.
    private static func workspace(_ index: Int, unread: Bool = false, group: WorkspaceGroupID? = nil,
                                  tabs: Int = tabsPerWorkspace) -> WorkspaceSnapshot {
        let tabs = (0..<tabs).map { tab in
            TabSnapshot(surface: surface(index, tab), title: "old",
                        notification: unread && tab == 0
                            ? TabNotification(notification: NotificationID(rawValue: UInt64(index + 1)), unread: true) : nil)
        }
        let pane = PaneSnapshot(id: pane(index), tabs: tabs)
        let screen = ScreenSnapshot(id: screen(index), layout: .leaf(pane.id), panes: [pane])
        return WorkspaceSnapshot(id: handle(index), key: WorkspaceKey(rawValue: "ws-\(index)"), name: "w\(index)", screens: [screen],
                                 group: group)
    }

    /// 50 workspaces of 20 tabs (1000 tabs) and one group; every fifth workspace has one unread
    /// tab. Driven by an unstarted connection (no socket is touched) and a clock that moves 300 us
    /// per read.
    private static func drivenStore() -> DaemonStore {
        let store = DaemonStore()
        store.drainClock = SteppingClock(step: .microseconds(300))
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: (0..<workspaces).map { workspace($0, unread: $0 % 5 == 0) },
                                         groups: [WorkspaceGroupSnapshot(id: group, name: "A")]))
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-drain-cost-test.sock"))
        store.driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: NextTurnFrameScheduler())
        return store
    }

    /// Queues one title event for every tab of every workspace (1000 events).
    private static func queueTitleStorm(_ driver: StoreDriver) {
        var sequence: UInt64 = 1
        for workspace in 0..<workspaces {
            for tab in 0..<tabsPerWorkspace {
                sequence += 1
                _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: .titleChanged(
                    surface: surface(workspace, tab), title: "new \(workspace).\(tab)")))
            }
        }
    }

    private func expectUnreadConsistent(_ store: DaemonStore, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(store.unreadTotals == store.recountedUnreadTotals(), comment, sourceLocation: sourceLocation)
    }

    /// The acceptance: 1000 title events across 50 workspaces in one batch flatten the sidebar 0
    /// times, run no membership pass and join no workspace to the unread sum again.
    @Test func aThousandTitleEventsAcrossFiftyWorkspacesFlattenNoSidebar() throws {
        let store = Self.drivenStore()
        let driver = try #require(store.driver)
        var listRuns = 0
        store.onWorkspaceListChanged = { listRuns += 1 }
        let before = store.drainCost
        let joins = store.index.unread.joins
        Self.queueTitleStorm(driver)
        store.drain()
        let cost = store.drainCost
        #expect(cost.sidebarFlattens - before.sidebarFlattens == 0, "title events flattened the sidebar")
        #expect(cost.listChanges - before.listChanges == 0)
        #expect(listRuns == 0, "title events ran the membership pass")
        #expect(store.index.unread.joins - joins == 0, "title events summed workspaces again")
        #expect(cost.batches - before.batches == 1)
        #expect(cost.events - before.events == 1000)
        #expect(store.tab(surface: Self.surface(49, 19))?.title == "new 49.19")
        #expect(store.tab(surface: Self.surface(0, 0))?.title == "new 0.0")
        expectUnreadConsistent(store, "after the title storm")
    }

    /// With Cmd-N's workspace still pending, every batch lifts and restores its overlay: the same
    /// overlay back flattens nothing, and the sidebar still shows the pending workspace.
    @Test func aTitleStormWithAPendingNewWorkspaceFlattensNoSidebar() throws {
        let store = Self.drivenStore()
        let driver = try #require(store.driver)
        let key = WorkspaceKey.generate()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "new", tab: Self.page()), index: nil),
                     transaction: .generate())
        let pending = try #require(store.workspace(id: key.rawValue))
        #expect(store.sidebarSections.contains { $0.workspaces.contains { $0 === pending } })
        let before = store.drainCost.sidebarFlattens
        Self.queueTitleStorm(driver)
        store.drain()
        #expect(store.drainCost.sidebarFlattens == before, "the lift and restore of the same overlay flattened the sidebar")
        #expect(store.pendingIntents.count == 1)
        #expect(store.workspaces.last === pending)
        #expect(store.sidebarSections.contains { $0.workspaces.contains { $0 === pending } })
        #expect(store.tab(surface: Self.surface(3, 4))?.title == "new 3.4")
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A full snapshot under a pending new workspace re-indexes everything with the overlay lifted:
    /// the sidebar is flattened once the overlay is back, so it still shows the pending workspace.
    @Test func aFullSnapshotUnderAPendingNewWorkspaceKeepsItInTheSidebar() throws {
        let store = Self.drivenStore()
        let key = WorkspaceKey.generate()
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "new", tab: Self.page()), index: nil),
                     transaction: .generate())
        let pending = try #require(store.workspace(id: key.rawValue))
        // Another registry: the memo cannot vouch, so the whole tree applies and the index is rebuilt.
        store.apply(snapshot: DaemonTree(registryID: "registry-2", workspaceRevision: 5,
                                         workspaces: (0..<Self.workspaces).map { Self.workspace($0, unread: $0 % 5 == 0) },
                                         groups: [WorkspaceGroupSnapshot(id: Self.group, name: "A")]))
        #expect(store.workspace(id: key.rawValue) === pending)
        #expect(store.sidebarSections.contains { $0.workspaces.contains { $0 === pending } },
                "the sidebar was flattened with the overlay lifted")
        #expect(store.sidebarSections.map(\.workspaces.count).reduce(0, +) == store.workspaces.count)
    }

    /// A replayed `workspaceAdded` of a workspace already listed flattens nothing; the same replay
    /// that names another group flattens once and shows it in that group.
    @Test func aReplayedAddFlattensOnlyForAGroupChange() throws {
        let store = Self.drivenStore()
        let before = store.drainCost.sidebarFlattens
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: Self.handle(7), index: 7, entity: Self.workspace(7),
                                                   workspaceRevision: 2)))
        #expect(store.drainCost.sidebarFlattens == before, "a replayed add of a listed workspace flattened the sidebar")
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: Self.handle(7), index: 7, entity: Self.workspace(7, group: Self.group),
                                                   workspaceRevision: 3)))
        #expect(store.drainCost.sidebarFlattens == before + 1)
        let model = try #require(store.workspace(handle: Self.handle(7)))
        #expect(store.sidebarSections.first { $0.group?.id == Self.group }?.workspaces.contains { $0 === model } == true)
        #expect(store.workspaces.count == Self.workspaces)
    }

    /// A batch of 100 moves re-indexes the moved workspaces only (100 joins of the unread sum,
    /// not 100 walks of 50), flattens the sidebar once and keeps the membership.
    @Test func aBatchOfMovesSumsTheMovedWorkspacesOnlyAndFlattensOnce() throws {
        let store = Self.drivenStore()
        let driver = try #require(store.driver)
        var listRuns = 0
        store.onWorkspaceListChanged = { listRuns += 1 }
        let before = store.drainCost
        let joins = store.index.unread.joins
        for move in 0..<100 {
            let workspace = (move * 7) % Self.workspaces
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(move + 2), event: .workspaceMoved(WorkspaceDelta(
                workspace: Self.handle(workspace), index: 0, entity: Self.workspace(workspace, unread: workspace % 5 == 0),
                workspaceRevision: UInt64(move + 2)))))
        }
        store.drain()
        #expect(store.workspaces.first?.handle == Self.handle((99 * 7) % Self.workspaces))
        #expect(store.index.unread.joins - joins == 100, "the moves joined \(store.index.unread.joins - joins) workspaces")
        #expect(store.drainCost.sidebarFlattens - before.sidebarFlattens == 1, "one flattening per batch")
        #expect(listRuns == 0, "moves ran the membership pass")
        #expect(store.unreadBadge() == Self.workspaces / 5)
        expectUnreadConsistent(store, "after the moves")
    }

    /// The unread sum's work is the moves', whatever the list holds: 10 moves in a store of 1000
    /// workspaces join 10 workspaces (the per-move re-sum of every workspace is gone).
    @Test func tenMovesInAThousandWorkspacesJoinTenWorkspaces() {
        let count = 1000
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1,
                                         workspaces: (0..<count).map { Self.workspace($0, unread: $0 % 10 == 0, tabs: 1) }))
        let joins = store.index.unread.joins
        let flattens = store.drainCost.sidebarFlattens
        store.apply(batch: (0..<10).map { move in
            let workspace = move * 97
            return DaemonEventEnvelope(sequence: UInt64(move + 1), event: .workspaceMoved(WorkspaceDelta(
                workspace: Self.handle(workspace), index: 0, entity: Self.workspace(workspace, unread: workspace % 10 == 0, tabs: 1),
                workspaceRevision: UInt64(move + 2))))
        })
        #expect(store.workspaces.first?.handle == Self.handle(9 * 97))
        #expect(store.index.unread.joins - joins == 10, "10 moves joined \(store.index.unread.joins - joins) workspaces")
        #expect(store.drainCost.sidebarFlattens - flattens == 1)
        #expect(store.unreadBadge() == count / 10)
        expectUnreadConsistent(store, "after the moves")
    }

    /// A move to where the workspace already is (a script's repeated reorder) flattens nothing.
    @Test func aMoveToItsOwnPlaceFlattensNothing() {
        let store = Self.drivenStore()
        let before = store.drainCost.sidebarFlattens
        store.apply(.workspaceMoved(WorkspaceDelta(workspace: Self.handle(5), index: 5, entity: Self.workspace(5, unread: true),
                                                   workspaceRevision: 2)))
        #expect(store.workspaces[5].handle == Self.handle(5))
        #expect(store.drainCost.sidebarFlattens == before)
    }

    /// A workspace that joins or leaves runs the membership pass once; the sum follows it.
    @Test func aJoinAndALeaveChangeTheListAndTheSumOnce() {
        let store = Self.drivenStore()
        var listRuns = 0
        store.onWorkspaceListChanged = { listRuns += 1 }
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: Self.handle(60), index: 0, entity: Self.workspace(60, unread: true),
                                                   workspaceRevision: 2)))
        #expect(listRuns == 1)
        #expect(store.unreadBadge() == Self.workspaces / 5 + 1)
        store.apply(.workspaceClosed(WorkspaceDelta(workspace: Self.handle(0), index: nil, entity: Self.workspace(0, unread: true),
                                                    workspaceRevision: 3)))
        #expect(listRuns == 2)
        #expect(store.unreadBadge() == Self.workspaces / 5)
        expectUnreadConsistent(store, "after a join and a leave")
    }

    /// A snapshot the memo cannot vouch for rebuilds the index: the sum leaves and joins every
    /// workspace and ends equal to a count from every tab; a dropped workspace no longer counts,
    /// even when its record changes later.
    @Test func aFullSnapshotKeepsTheSumAndDropsTheWorkspacesItRemoves() throws {
        let store = Self.drivenStore()
        let dropped = try #require(store.workspace(handle: Self.handle(10)))
        let droppedTab = try #require(store.tab(surface: Self.surface(10, 0)))
        // Another registry: the memo cannot vouch, so the whole tree applies and the index is rebuilt.
        store.apply(snapshot: DaemonTree(registryID: "registry-2", workspaceRevision: 5,
                                         workspaces: (0..<Self.workspaces).filter { $0 != 10 }.map { Self.workspace($0, unread: $0 % 5 == 0) }))
        #expect(store.workspace(handle: Self.handle(10)) == nil)
        #expect(dropped.unreadLedger == nil)
        #expect(store.unreadBadge() == Self.workspaces / 5 - 1)
        droppedTab.expectNotificationRead()
        #expect(store.unreadBadge() == Self.workspaces / 5 - 1, "a dropped workspace still reported to the sum")
        expectUnreadConsistent(store, "after a full snapshot")
    }

    /// Each drain is one sample of the histogram at the clock's time; an empty inbox is none, and
    /// a reset clears the samples and the counters.
    @Test func eachDrainIsOneSampleOfTheHistogram() throws {
        let store = Self.drivenStore()
        let driver = try #require(store.driver)
        for round in 0..<3 {
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(round + 2), event: .titleChanged(
                surface: Self.surface(round, 0), title: "round \(round)")))
            store.drain()
        }
        store.drain()
        let histogram = store.drainCost.histogram
        #expect(store.drainCost.batches == 3)
        #expect(store.drainCost.events == 3)
        #expect(histogram.counts[MainOwnerLedger.Histogram.bucket(of: 300_000)] == 3)
        #expect(histogram.maxNanos == 300_000)
        #expect(histogram.percentile(0.99) == 300_000)
        store.resetDrainCost()
        #expect(store.drainCost == DrainCost())
    }

    private static func page() -> TabSnapshot {
        ProvisionalTab().conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", hostName: nil)))
    }
}

/// A clock that moves `step` on every read of `now`: a drain (two reads) takes exactly `step`.
private final class SteppingClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let step: Duration
    private let reads = Mutex(Duration.zero)

    init(step: Duration) {
        self.step = step
    }

    var now: Instant {
        reads.withLock { offset in
            defer { offset += step }
            return Instant(offset: offset)
        }
    }

    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw CancellationError()
    }
}

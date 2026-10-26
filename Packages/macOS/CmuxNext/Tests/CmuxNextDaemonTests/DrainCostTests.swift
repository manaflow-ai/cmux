@testable import CmuxNextDaemon
import CmuxNextCompat
import Testing

/// A drain of the event inbox costs what changed (p06-scheduler-033): the sidebar flattening, the
/// workspace-list check and the unread sum run for the workspaces a batch names, never for the
/// list. A storm of title events in hidden workspaces flattens no sidebar and walks no workspace;
/// a batch of moves sums the moved workspaces only. ``DrainCost`` counts each drain in a histogram
/// (owner `DaemonStore.drain`), which script-storm-bench `--hidden` reads for its p99.
@MainActor @Suite struct DrainCostTests {
    private static let workspaces = 50
    private static let tabsPerWorkspace = 20

    private static func surface(_ workspace: Int, _ tab: Int) -> SurfaceID { SurfaceID(rawValue: UInt64(workspace * 100 + 10 + tab)) }
    private static func pane(_ workspace: Int) -> PaneID { PaneID(rawValue: UInt64(workspace * 100 + 1)) }
    private static func screen(_ workspace: Int) -> ScreenID { ScreenID(rawValue: UInt64(workspace * 100 + 2)) }
    private static func handle(_ workspace: Int) -> WorkspaceHandle { WorkspaceHandle(rawValue: UInt64(workspace * 100 + 3)) }

    /// Workspace `index`; its first tab has an unread notification when `unread`.
    private static func workspace(_ index: Int, unread: Bool = false) -> WorkspaceSnapshot {
        let tabs = (0..<tabsPerWorkspace).map { tab in
            TabSnapshot(surface: surface(index, tab), title: "old",
                        notification: unread && tab == 0
                            ? TabNotification(notification: NotificationID(rawValue: UInt64(index + 1)), unread: true) : nil)
        }
        let pane = PaneSnapshot(id: pane(index), tabs: tabs)
        let screen = ScreenSnapshot(id: screen(index), layout: .leaf(pane.id), panes: [pane])
        return WorkspaceSnapshot(id: handle(index), key: WorkspaceKey(rawValue: "ws-\(index)"), name: "w\(index)", screens: [screen])
    }

    /// 50 workspaces of 20 tabs (1000 tabs); every fifth workspace has one unread tab. Driven by an
    /// unstarted connection (no socket is touched) and a clock that moves 300 us per read.
    private static func drivenStore(registryID: String? = nil) -> DaemonStore {
        let store = DaemonStore()
        store.drainClock = SteppingClock(step: .microseconds(300))
        store.apply(snapshot: DaemonTree(registryID: registryID, workspaceRevision: 1,
                                         workspaces: (0..<workspaces).map { workspace($0, unread: $0 % 5 == 0) }))
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-drain-cost-test.sock"))
        store.driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: NextTurnFrameScheduler())
        return store
    }

    private func expectUnreadConsistent(_ store: DaemonStore, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(store.unreadTotals == store.recountedUnreadTotals(), comment, sourceLocation: sourceLocation)
    }

    /// The acceptance: 1000 title events across 50 workspaces in one batch flatten the sidebar 0
    /// times, run no membership pass and sum no workspace's unread count again.
    @Test func aThousandTitleEventsAcrossFiftyWorkspacesFlattenNoSidebar() throws {
        let store = Self.drivenStore()
        let driver = try #require(store.driver)
        var listRuns = 0
        store.onWorkspaceListChanged = { listRuns += 1 }
        let before = store.drainCost
        let joins = store.index.unread.joins
        var sequence: UInt64 = 1
        for workspace in 0..<Self.workspaces {
            for tab in 0..<Self.tabsPerWorkspace {
                sequence += 1
                _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: .titleChanged(
                    surface: Self.surface(workspace, tab), title: "new \(workspace).\(tab)")))
            }
        }
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

    /// The histogram: one sample per drain at the clock's time, four buckets per power of two, and
    /// a p99 that names the bucket's upper edge.
    @Test func eachDrainIsOneSampleOfTheHistogram() throws {
        let store = Self.drivenStore()
        let driver = try #require(store.driver)
        for round in 0..<3 {
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(round + 2), event: .titleChanged(
                surface: Self.surface(round, 0), title: "round \(round)")))
            store.drain()
        }
        // An empty inbox is no drain.
        store.drain()
        let cost = store.drainCost
        #expect(cost.batches == 3)
        #expect(cost.buckets[DrainCost.bucket(micros: 300)] == 3)
        #expect(cost.maxMicros == 300)
        #expect(cost.percentileMicros(0.99) == 300)
        #expect(cost.percentileMicros(0.99) <= 1_000, "script-storm-bench --hidden budget")
    }

    @Test func bucketsAreFourPerPowerOfTwo() {
        #expect(DrainCost.bucket(micros: 0) == 0)
        #expect(DrainCost.bucket(micros: 1) == 1)
        #expect(DrainCost.bucket(micros: 256) == 1 + 4 * 8)
        #expect(DrainCost.bucket(micros: 319) == 1 + 4 * 8)
        #expect(DrainCost.bucket(micros: 320) == 2 + 4 * 8)
        #expect(DrainCost.bucket(micros: 511) == 4 + 4 * 8)
        #expect(DrainCost.bucket(micros: 512) == 1 + 4 * 9)
        #expect(DrainCost.bucket(micros: DrainCost.maximumMicros) == DrainCost.bucketCount - 1)
        #expect(DrainCost.upperEdgeMicros(DrainCost.bucket(micros: 256)) == 320)
        #expect(DrainCost.upperEdgeMicros(DrainCost.bucket(micros: 511)) == 512)
        for micros: Int64 in [1, 3, 7, 100, 999, 1_000, 65_537, 900_000] {
            let bucket = DrainCost.bucket(micros: micros)
            #expect(micros < DrainCost.upperEdgeMicros(bucket), "\(micros) us is under its bucket's upper edge")
            #expect(bucket == 0 || micros >= DrainCost.upperEdgeMicros(bucket - 1), "\(micros) us is at or over the bucket below")
        }
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

@testable import CmuxNextDaemon
import CmuxNextWakeups
import Testing

/// The drain's tail is bounded and cut on real daemon output (``DrainTail``,
/// ``TransactionRun``): a whole-value event replaces the waiting one of its field, a storm past the
/// limit collapses into one snapshot, an untagged storm spreads over tasks, and a request's untagged
/// events stay with its tagged ones.
@MainActor @Suite struct DrainTailBoundsTests {
    /// One workspace, one pane, tabs on surfaces 1...4 titled "old", driven by an unstarted connection
    /// (a snapshot request fails at once) with `tasks` and a tail of at most `limit` events.
    private func makeStore(tasks: TailTasks, limit: Int = EventInbox.defaultLimit) -> (DaemonStore, StoreDriver) {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: (1...4).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "old") })
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-drain-tail-bounds-test.sock"))
        let driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: NextTurnFrameScheduler(), tail: tasks,
                                 tailLimit: limit)
        store.driver = driver
        return (store, driver)
    }

    private func title(_ store: DaemonStore, _ surface: Int) -> String? {
        store.tab(surface: SurfaceID(rawValue: UInt64(surface)))?.title
    }

    private func rename(_ surface: Int, _ title: String, transaction: String?) -> DaemonEvent {
        let id = SurfaceID(rawValue: UInt64(surface))
        return .tabRenamed(TabDelta(workspace: 1, screen: 1, pane: 1, surface: id, index: nil, entity: TabSnapshot(surface: id, title: title),
                                    clientTransactionID: transaction.map { ClientTransactionID(rawValue: $0) }))
    }

    private func append(_ driver: StoreDriver, _ sequence: inout UInt64, _ event: DaemonEvent, cause: ObservationCause = .automation) {
        sequence += 1
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: event, cause: cause))
    }

    /// A storm past the tail's limit collapses it into one snapshot in the frame (the tail does not
    /// grow), and the echoes it held still confirm their transactions.
    @Test func aStormPastTheLimitCollapsesTheTailIntoOneSnapshot() async throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tasks: tasks, limit: 8)
        var sequence: UInt64 = 0
        for index in 0..<3 {
            for surface in 1...2 { append(driver, &sequence, rename(surface, "a\(index)", transaction: "tx-a\(index)")) }
        }
        store.drain()
        #expect(store.drainTailCount == 3)
        #expect(!store.isResyncing)
        for index in 3..<5 {
            for surface in 1...2 { append(driver, &sequence, rename(surface, "a\(index)", transaction: "tx-a\(index)")) }
        }
        store.drain()
        #expect(store.drainTailCount == 0, "the tail grew past its limit")
        #expect(store.isResyncing, "the collapsed tail did not ask for a snapshot")
        #expect(store.confirmedTransactions.contains(ClientTransactionID(rawValue: "tx-a0")))
        #expect(store.confirmedTransactions.contains(ClientTransactionID(rawValue: "tx-a4")))
        await store.refresh()
        #expect(!store.isResyncing)
        while tasks.runNext() != nil {}
        #expect(store.drainTailCount == 0)
    }

    /// A newer title of a surface replaces the one waiting in the tail: the tail keeps one per field
    /// and applies the newest.
    @Test func aNewerTitleReplacesTheOneWaitingInTheTail() throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tasks: tasks)
        var sequence: UInt64 = 0
        append(driver, &sequence, .titleChanged(surface: 3, title: "t0"))
        append(driver, &sequence, rename(1, "a", transaction: nil))
        store.drain()
        #expect(store.drainTailCount == 2)
        for index in 1...50 { append(driver, &sequence, .titleChanged(surface: 3, title: "t\(index)")) }
        store.drain()
        #expect(store.drainTailCount == 2, "stale titles waited in the tail")
        #expect(driver.tail.coalescedCount == 1)
        append(driver, &sequence, .titleChanged(surface: 3, title: "last"))
        store.drain()
        #expect(store.drainTailCount == 2)
        var runs = 0
        while tasks.runNext() != nil { runs += 1 }
        #expect(runs == 2)
        #expect(title(store, 1) == "a")
        #expect(title(store, 3) == "last")
        #expect(store.appliedSequence == sequence)
    }

    /// [auto x1000] untagged, as the CLI and agents send tree changes: the storm spreads over tasks, a
    /// task applies at most ``TransactionRun/untaggedLimit`` of them with its share spent.
    @Test func aThousandUntaggedAutomationRenamesSpreadOverTasks() throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tasks: tasks)
        var sequence: UInt64 = 0
        for index in 0..<1000 { append(driver, &sequence, rename(index % 2 + 1, "u\(index)", transaction: nil)) }
        store.drain()
        #expect(title(store, 1) == "old", "automation applied in the frame")
        let limit = TransactionRun.untaggedLimit
        #expect(store.drainTailCount == (1000 + limit - 1) / limit)
        var runs = 0
        var before = store.appliedSequence
        while tasks.runNext() != nil {
            runs += 1
            #expect(store.appliedSequence - before <= UInt64(limit), "task \(runs) applied a whole storm")
            before = store.appliedSequence
        }
        #expect(runs == (1000 + limit - 1) / limit)
        #expect(title(store, 1) == "u998")
        #expect(title(store, 2) == "u999")
        #expect(store.appliedSequence == sequence)
    }

    /// A browser create in a new screen: the daemon sends `screen-added` untagged and the `tab-added`
    /// tagged with the client's transaction. One transaction: one task applies both, share spent.
    @Test func anUntaggedScreenAddAndItsTaggedTabAddApplyInOneTask() throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tasks: tasks)
        let screen = ScreenSnapshot(id: 2, layout: .leaf(2), panes: [PaneSnapshot(id: 2, tabs: [])])
        let screenAdded = DaemonEvent.screenAdded(ScreenDelta(workspace: 1, screen: 2, index: nil, entity: screen))
        let tab = TabSnapshot(surface: SurfaceID(rawValue: 10), title: "web")
        let tabAdded = DaemonEvent.tabAdded(TabDelta(workspace: 1, screen: 2, pane: 2, surface: SurfaceID(rawValue: 10), index: 0, entity: tab,
                                                     clientTransactionID: ClientTransactionID(rawValue: "X")))
        var sequence: UInt64 = 0
        append(driver, &sequence, screenAdded)
        append(driver, &sequence, tabAdded)
        append(driver, &sequence, rename(1, "next", transaction: "Y"))
        store.drain()
        #expect(store.drainTailCount == 2, "the request was cut in two, or joined the next one")
        tasks.runNext()
        #expect(store.drainTailCount == 1)
        #expect(title(store, 1) == "old")
    }

    /// The cut itself: one tag joins its untagged neighbours of one cause; another tag, another cause
    /// or a whole-value event starts the next transaction.
    @Test func transactionRunsJoinOneTagWithItsUntaggedNeighbours() {
        func envelope(_ sequence: UInt64, _ event: DaemonEvent, _ cause: ObservationCause = .automation) -> DaemonEventEnvelope {
            DaemonEventEnvelope(sequence: sequence, event: event, cause: cause)
        }
        let batch = [
            envelope(1, rename(1, "a", transaction: nil)),
            envelope(2, rename(2, "a", transaction: "X")),
            envelope(3, rename(3, "a", transaction: nil)),
            envelope(4, rename(1, "b", transaction: "Y")),
            envelope(5, rename(2, "b", transaction: nil), .program),
            envelope(6, .titleChanged(surface: 3, title: "t")),
            envelope(7, rename(3, "c", transaction: nil)),
        ]
        #expect(DrainTail.transactions(in: batch).map { $0.envelopes.map(\.sequence) } == [[1, 2, 3], [4], [5], [6], [7]])
    }
}

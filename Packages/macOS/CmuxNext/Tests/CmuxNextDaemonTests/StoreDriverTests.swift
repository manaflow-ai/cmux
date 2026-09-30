import Foundation
import Observation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// Holds frame requests until the test flushes them, like a display link
/// that fires when the test says so.
final class ManualFrameScheduler: FrameScheduler {
    private let pending = Mutex<[@MainActor @Sendable () -> Void]>([])
    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        pending.withLock { $0.append(work) }
    }
    var count: Int { pending.withLock { $0.count } }
    @MainActor func flush() {
        for work in pending.withLock({ items in defer { items.removeAll() }; return items }) { work() }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct StoreDriverTests {
    private func loadedStore() throws -> (DaemonStore, DaemonTree) {
        let store = DaemonStore()
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        store.apply(snapshot: tree)
        return (store, tree)
    }

    @Test func batchSkipsEventsSupersededBySnapshot() throws {
        let (store, _) = try loadedStore()
        store.snapshotBarrier = 10
        store.apply(batch: [
            DaemonEventEnvelope(sequence: 5, event: .titleChanged(surface: 3, title: "stale")),
            DaemonEventEnvelope(sequence: 11, event: .titleChanged(surface: 3, title: "new")),
        ])
        #expect(store.tab(surface: 3)?.title == "new")
        store.apply(batch: [DaemonEventEnvelope(sequence: 9, event: .titleChanged(surface: 3, title: "older"))])
        #expect(store.tab(surface: 3)?.title == "new")
    }

    @Test func optimisticMoveSurvivesSnapshotsUntilEcho() throws {
        let (store, tree) = try loadedStore()
        let tab = try #require(store.tab(surface: 3))
        store.applyOptimistic(.moveTab(surface: 3, toPane: 7, index: 0), transaction: "tx")
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])
        #expect(store.pane(4)?.tabs.map(\.surface) == [13])
        #expect(store.pane(7)?.tabs.first === tab)

        // An unrelated snapshot (daemon has not processed the move yet).
        store.apply(snapshot: tree)
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])

        // The echo drops the patch; the next snapshot is daemon truth.
        let echo = TabDelta(workspace: 1, screen: 5, pane: 7, surface: 3, index: 0, entity: tab.snapshot, clientTransactionID: "tx")
        store.apply(.tabChanged(echo))
        #expect(!store.hasPendingPatches)
        store.apply(snapshot: tree)
        #expect(store.pane(7)?.tabs.map(\.surface) == [6])
        #expect(store.pane(4)?.tabs.map(\.surface) == [3, 13])
    }

    @Test func echoSupersededBySnapshotStillSettlesPatch() throws {
        let (store, _) = try loadedStore()
        store.applyOptimistic(.renameWorkspace(key: "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1", name: "renamed"), transaction: "tx")
        store.snapshotBarrier = 100
        let echo = TabDelta(workspace: 1, screen: 5, pane: 7, surface: 6, index: 0, entity: TabSnapshot(surface: 6), clientTransactionID: "tx")
        store.apply(batch: [DaemonEventEnvelope(sequence: 50, event: .tabChanged(echo))])
        #expect(!store.hasPendingPatches)
        #expect(store.confirmedTransactions == ["tx"])
    }

    @Test func rejectedAndUnechoedPatchesAreDropped() throws {
        let (store, tree) = try loadedStore()
        let key: WorkspaceKey = "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1"
        store.applyOptimistic(.renameWorkspace(key: key, name: "optimistic"), transaction: "t1")
        #expect(store.workspace(key: key)?.name == "optimistic")
        store.rejectOptimistic("t1")
        store.apply(snapshot: tree)
        #expect(store.workspace(key: key)?.name == "beta")

        store.applyOptimistic(.setTabPinned(surface: 3, pinned: true), transaction: "t2")
        store.settleOptimistic("t2")
        #expect(store.tab(surface: 3)?.pinned == true)
        store.apply(snapshot: tree)
        #expect(store.tab(surface: 3)?.pinned == false)
        #expect(!store.hasPendingPatches)
    }

    @Test func fieldChangesDoNotInvalidateCollections() throws {
        let (store, tree) = try loadedStore()
        let pane = try #require(store.pane(4))
        let tab = try #require(store.tab(surface: 3))
        let collectionsChanged = Mutex(false)
        let titleChanged = Mutex(false)
        withObservationTracking {
            _ = store.workspaces
            _ = pane.tabs
            _ = store.sidebarSections
        } onChange: { collectionsChanged.withLock { $0 = true } }
        withObservationTracking { _ = tab.title } onChange: { titleChanged.withLock { $0 = true } }

        var next = tree
        next.workspaces[0].screens[0].panes[0].tabs[0].title = "vim"
        store.apply(snapshot: next)
        #expect(tab.title == "vim")
        #expect(titleChanged.withLock { $0 })
        #expect(!collectionsChanged.withLock { $0 })

        // An identical snapshot changes nothing at all.
        let quiet = Mutex(false)
        withObservationTracking { _ = tab.title; _ = tab.size; _ = pane.groupSpans } onChange: { quiet.withLock { $0 = true } }
        store.apply(snapshot: next)
        #expect(!quiet.withLock { $0 })
    }

    @Test func sidebarSectionsAndTabGroupSpans() throws {
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        tree.groups = [WorkspaceGroupSnapshot(id: "g1", name: "Agents", index: 0)]
        tree.workspaces[1].group = "g1"
        tree.workspaces[0].screens[0].panes[0].tabGroups = [TabGroupSnapshot(id: "tg", name: "API", surfaces: [3, 13])]
        tree.workspaces[0].screens[0].panes[0].tabs[0].tabGroup = "tg"
        tree.workspaces[0].screens[0].panes[0].tabs[1].tabGroup = "tg"
        let store = DaemonStore()
        store.apply(snapshot: tree)
        #expect(store.sidebarSections.map { $0.group?.name } == [nil, "Agents"])
        #expect(store.sidebarSections.map { $0.workspaces.map(\.name) } == [["beta"], ["gamma"]])
        #expect(store.pane(4)?.groupSpans == [TabGroupSpan(group: "tg", range: 0..<2)])
        #expect(store.tabGroup("tg")?.name == "API")

        store.applyOptimistic(.setWorkspaceGroup(key: "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1", group: "g1"), transaction: "t")
        #expect(store.sidebarSections.map { $0.workspaces.map(\.name) } == [[], ["beta", "gamma"]])
    }

    @Test func runAppliesBurstsInOneFrame() async throws {
        let tree = String(decoding: try Fixture.data("list-workspaces.json"), as: UTF8.self).trimmingCharacters(in: .newlines)
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            switch request["cmd"]?.stringValue {
            case "list-workspaces":
                return [tree.replacingOccurrences(of: #""id":0,"#, with: #""id":\#(id),"#)]
            case "list-agents":
                return [#"{"id":\#(id),"ok":true,"data":{"agents":[{"surface":3,"state":"working","source":"hook","session":null,"updated_at_ms":1}]}}"#]
            default:
                return []
            }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        let store = DaemonStore()
        let scheduler = ManualFrameScheduler()
        let run = Task { await store.run(connection: connection, scheduler: scheduler) }

        try await waitFor { scheduler.count == 1 }
        scheduler.flush() // .connected -> resync (snapshot + agents)
        try await waitFor { store.isLoaded && store.tab(surface: 3)?.agent?.state == .working }

        for index in 0..<50 { server.push(#"{"event":"title-changed","surface":3,"title":"t\#(index)"}"#) }
        try await waitFor { scheduler.count == 1 }
        try await Task.sleep(for: .milliseconds(100)) // let the whole burst land in the inbox
        #expect(scheduler.count == 1)
        scheduler.flush()
        #expect(store.tab(surface: 3)?.title == "t49")

        await connection.close()
        await run.value
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw DaemonError.timedOut("condition") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct TerminalEventQueueTests {
    @Test func mergesOutputAndKeepsOrder() async {
        let queue = TerminalEventQueue()
        queue.push(.output(Data("a".utf8), colors: nil))
        queue.push(.output(Data("b".utf8), colors: nil))
        queue.push(.scrollChanged(offset: 1, atBottom: false))
        queue.push(.output(Data("c".utf8), colors: nil))
        queue.finish(.closed(.surfaceGone))
        #expect(await queue.next() == .output(Data("ab".utf8), colors: nil))
        #expect(await queue.next() == .scrollChanged(offset: 1, atBottom: false))
        #expect(await queue.next() == .output(Data("c".utf8), colors: nil))
        #expect(await queue.next() == .closed(.surfaceGone))
        #expect(await queue.next() == nil)
    }

    @Test func readerBlocksAboveHighWaterUntilConsumerDrains() async throws {
        let queue = TerminalEventQueue(highWater: 10, lowWater: 4, mergeLimit: 1 << 20)
        queue.arm()
        let produced = Mutex(0)
        let thread = Thread {
            for _ in 0..<6 {
                queue.push(.output(Data(repeating: 0x41, count: 5), colors: nil))
                produced.withLock { $0 += 1 }
            }
        }
        thread.start()
        try await Task.sleep(for: .milliseconds(200))
        // 3 chunks (15 bytes) exceed the 10-byte high water: the third push blocks.
        #expect(produced.withLock { $0 } == 2)
        #expect(queue.bufferedOutputBytes == 15)
        guard case .output(let first, _)? = await queue.next() else {
            Issue.record("expected output")
            return
        }
        #expect(first.count == 15)
        var drained = first.count
        while drained < 30 {
            guard case .output(let data, _)? = await queue.next() else { break }
            drained += data.count
        }
        #expect(drained == 30)
        #expect(produced.withLock { $0 } == 6)
    }

    @Test func replayNeverBlocksBeforeArm() {
        let queue = TerminalEventQueue(highWater: 1, lowWater: 0)
        queue.push(.replay(TerminalReplay(cols: 1, rows: 1, data: Data(count: 100))))
        queue.push(.output(Data(count: 100), colors: nil))
        #expect(queue.bufferedOutputBytes == 100)
    }
}

/// `appliedSequence` is the compat write barrier's clock: it passes a
/// sequence only once the tree reflects every event up to it.
@MainActor @Suite struct AppliedSequenceTests {
    @Test func advancesAfterAnExactBatchButNotBeforeAResync() {
        let store = DaemonStore()
        store.apply(batch: [DaemonEventEnvelope(sequence: 4, event: .titleChanged(surface: 3, title: "a"))])
        #expect(store.appliedSequence == 4)
        // A coarse invalidation is reflected only once its snapshot lands.
        #expect(store.apply(batch: [DaemonEventEnvelope(sequence: 6, event: .treeChanged(transaction: nil))]) == .resync)
        #expect(store.appliedSequence == 4)
        store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: .titleChanged(surface: 3, title: "old"))])
        #expect(store.appliedSequence == 4)
    }
}

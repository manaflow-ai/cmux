import Foundation
import Testing
@testable import CmuxNextDaemon

/// tab-drag-v1 reports a tab move as the moved tab's `tab-changed`, which
/// names the tab's new pane (cmux-tui docs/protocol.md). Dogfood tear-off on
/// tagged build tdrag2: after `move-tab-to-new-workspace` the daemon held
/// the tab in the new workspace's pane, but the app showed that pane empty
/// and the old pane still holding the tab until a relaunch.
@MainActor @Suite struct TabMoveDeltaTests {
    private func loadedStore() throws -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        return store
    }

    /// The fixture's own snapshot of surface 3 (pane 4), as the daemon sends it.
    private func entity3() throws -> TabSnapshot {
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        let tabs = tree.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        return try #require(tabs.first { $0.surface == 3 })
    }

    @Test func tabChangedNamingAnotherPaneMovesTheTab() throws {
        let store = try loadedStore()
        let tab = try #require(store.tab(surface: 3))
        let before = try #require(store.pane(4)).tabs.count
        let delta = TabDelta(workspace: 1, screen: 5, pane: 7, surface: 3, index: 1, entity: try entity3(),
                             clientTransactionID: "drop-1")
        #expect(store.apply(.tabChanged(delta)) == .none)
        #expect(store.pane(4)?.tabs.count == before - 1)
        #expect(store.pane(4)?.tabs.contains { $0.surface == 3 } == false)
        #expect(store.pane(7)?.tabs.map(\.surface) == [6, 3])
        #expect(store.pane(containing: 3)?.handle == 7)
        // The same model moves (views keyed by it keep their state).
        #expect(store.tab(surface: 3) === tab)
    }

    @Test func aRepeatedTabChangedIsIdempotent() throws {
        let store = try loadedStore()
        let delta = TabDelta(workspace: 1, screen: 5, pane: 7, surface: 3, index: 0, entity: try entity3())
        store.apply(.tabChanged(delta))
        store.apply(.tabChanged(delta))
        #expect(store.pane(7)?.tabs.map(\.surface) == [3, 6])
    }

    @Test func tabChangedNamingAnUnknownPaneResyncs() throws {
        let store = try loadedStore()
        let delta = TabDelta(workspace: 1, screen: 5, pane: 999, surface: 3, index: 0, entity: try entity3())
        #expect(store.apply(.tabChanged(delta)) == .resync)
    }
}

/// A drag's presentation ends once the store holds the daemon's result of
/// the drag's transaction (its echo), or a snapshot replaced the tree.
@MainActor @Suite struct TransactionAppliedTests {
    func loadedStore() throws -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        return store
    }

    private func echo(_ transaction: ClientTransactionID, in store: DaemonStore) throws {
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        let tab = try #require(tree.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.surface == 3 })
        store.apply(.tabChanged(TabDelta(workspace: 1, screen: 5, pane: 4, surface: 3, index: 0, entity: tab, clientTransactionID: transaction)))
    }

    @Test func runsOnceTheEchoIsApplied() throws {
        let store = try loadedStore()
        var ran = 0
        store.whenApplied("drop-7") { ran += 1 }
        #expect(ran == 0)
        try echo("drop-7", in: store)
        #expect(ran == 1)
        try echo("drop-7", in: store)
        #expect(ran == 1)
    }

    @Test func runsAtOnceWhenTheEchoAlreadyCame() throws {
        let store = try loadedStore()
        try echo("drop-8", in: store)
        var ran = false
        store.whenApplied("drop-8") { ran = true }
        #expect(ran)
    }

    @Test func aSnapshotRunsEveryWaiter() throws {
        let store = try loadedStore()
        var ran = false
        store.whenApplied("drop-9") { ran = true }
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        #expect(ran)
    }
}

extension TransactionAppliedTests {
    /// A command that changed nothing echoes nothing: the write barrier
    /// (every event before the reply applied) still ends the wait.
    @Test func runsWhenTheWriteBarrierIsApplied() throws {
        let store = try loadedStore()
        var ran = false
        store.whenApplied("drop-10", reaching: store.appliedSequence + 5) { ran = true }
        #expect(!ran)
        store.advanceAppliedSequence(to: store.appliedSequence + 5)
        #expect(ran)
        var now = false
        store.whenApplied("drop-11", reaching: store.appliedSequence) { now = true }
        #expect(now)
    }
}

extension TransactionAppliedTests {
    /// Inside an event batch the waiter runs once the whole batch is
    /// applied (the moved tab's later events too), never mid-batch.
    @Test func runsAfterTheWholeBatch() throws {
        let store = try loadedStore()
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        let tab = try #require(tree.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.surface == 3 })
        var titleAtRun: String?
        store.whenApplied("drop-12") { titleAtRun = store.tab(surface: 3)?.title }
        let base = store.appliedSequence
        store.apply(batch: [
            DaemonEventEnvelope(sequence: base + 1, event: .tabChanged(TabDelta(workspace: 1, screen: 5, pane: 7, surface: 3, index: 0,
                                                                                entity: tab, clientTransactionID: "drop-12"))),
            DaemonEventEnvelope(sequence: base + 2, event: .titleChanged(surface: 3, title: "after the move")),
        ])
        #expect(titleAtRun == "after the move")
    }

    /// A lost connection: no echo or barrier will come, every waiter runs.
    @Test func aDisconnectRunsEveryWaiter() throws {
        let store = try loadedStore()
        var ran = 0
        store.whenApplied("drop-13", reaching: store.appliedSequence + 100) { ran += 1 }
        store.whenApplied("drop-14") { ran += 1 }
        store.apply(.disconnected(reason: "socket closed"))
        #expect(ran == 2)
    }

    /// A snapshot from a resync that started before the reply may predate
    /// the move: a waiter with a write barrier waits for the barrier.
    @Test func aSnapshotDoesNotRunAWaiterWhoseBarrierIsAhead() throws {
        let store = try loadedStore()
        var ran = false
        store.whenApplied("drop-15", reaching: store.appliedSequence + 50) { ran = true }
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        #expect(!ran)
        store.advanceAppliedSequence(to: store.appliedSequence + 50)
        #expect(ran)
    }
}

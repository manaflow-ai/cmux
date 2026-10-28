import Foundation
import Testing
@testable import CmuxNextDaemon

/// The oracle's settle waits: `waitApplied(atLeast:since:)` and `waitIntentsIdle()` are
/// continuations the store resumes from its own state changes (the applied sequence advancing, the end of the
/// batch or run that changed the connection, the overlay lift that empties the intent log), never an observation
/// loop, a timer or a poll; a cancelled wait resumes and leaves no continuation behind.
@MainActor
struct StoreWaitsTests {
    private static let key = WorkspaceKey(rawValue: "w1")
    private static let workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "one")

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        return store
    }

    /// Runs the main actor until `count` waits are parked on their continuations (each yield lets a task run one step).
    private static func park(_ store: DaemonStore, waits count: Int) async {
        for _ in 0..<100 where store.pendingWaitCount < count { await Task.yield() }
    }

    private static func envelope(_ event: DaemonEvent, index: UInt64) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: 1, index: index), event: event)
    }

    @Test func aReachedSequenceReturnsAtOnce() async {
        let store = Self.store()
        store.advanceAppliedSequence(to: 7)
        #expect(await store.waitApplied(atLeast: 5, since: store.connectionEpoch) == .reached)
        #expect(await store.waitApplied(atLeast: 7, since: store.connectionEpoch) == .reached)
        #expect(store.pendingWaitCount == 0)
    }

    @Test func theAppliedSequenceAdvancingResumesTheWait() async {
        let store = Self.store()
        let epoch = store.connectionEpoch
        let waiting = Task { await store.waitApplied(atLeast: 3, since: epoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1)
        store.advanceAppliedSequence(to: 2)
        #expect(store.pendingWaitCount == 1, "a sequence below the barrier resumed the wait")
        store.advanceAppliedSequence(to: 3)
        #expect(await waiting.value == .reached)
        #expect(store.pendingWaitCount == 0)
    }

    @Test func aConnectionChangeEndsTheWait() async {
        let store = Self.store()
        let epoch = store.connectionEpoch
        let waiting = Task { await store.waitApplied(atLeast: 9, since: epoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1)
        store.apply(.disconnected(reason: "socket closed"))
        #expect(await waiting.value == .connectionChanged)
        #expect(await store.waitApplied(atLeast: 1, since: epoch) == .connectionChanged, "an old epoch waited")
        #expect(store.pendingWaitCount == 0)
    }

    /// The transport delivers a connection's events before the drop it synthesizes: one batch that applies the
    /// waited sequence and then the drop leaves the store holding that sequence, as `appliedThrough` reads it.
    @Test func aBatchThatReachesTheSequenceBeforeItsDropEndsReached() async {
        let store = Self.store()
        let epoch = store.connectionEpoch
        let sequence = DaemonEventEnvelope.sequence(serial: 1, index: 5)
        let waiting = Task { await store.waitApplied(atLeast: sequence, since: epoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1)
        _ = store.apply(batch: [
            Self.envelope(.unknown(name: "store-waits-test", payload: .null), index: 5),
            Self.envelope(.disconnected(reason: "socket closed"), index: DaemonEventEnvelope.lastIndex),
        ])
        #expect(await waiting.value == .reached, "the drop in the same batch hid the sequence it applied first")
        #expect(store.pendingWaitCount == 0)
    }

    /// A close, a pump failure or an incompatible daemon ends the event stream with no `disconnected` event:
    /// the run's end still ends the parked wait, as a connection change, not at the caller's deadline.
    @Test func aRunThatEndsWithoutADropEndsTheParkedWait() async {
        let store = Self.store()
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/tmp/cmux-store-waits-\(UUID().uuidString).sock"))
        let running = Task { await store.run(connection: connection) }
        let epoch = store.connectionEpoch
        let waiting = Task { await store.waitApplied(atLeast: 5, since: epoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1)
        await connection.close()
        await running.value
        #expect(await waiting.value == .connectionChanged)
        #expect(store.pendingWaitCount == 0)
    }

    @Test func cancellingTheWaitResumesItAndDropsTheContinuation() async {
        let store = Self.store()
        let epoch = store.connectionEpoch
        let waiting = Task { await store.waitApplied(atLeast: 50, since: epoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1)
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        for _ in 0..<100 where store.pendingWaitCount > 0 { await Task.yield() }
        #expect(store.pendingWaitCount == 0)
        #expect(store.sequenceWaits.isEmpty, "the cancelled wait kept its stage read-your-writes mark")
    }

    @Test func appliedThroughIsTheSameWait() async {
        let store = Self.store()
        let epoch = store.connectionEpoch
        let waiting = Task { await store.appliedThrough(4, since: epoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1, "appliedThrough did not park on the store's continuation")
        store.advanceAppliedSequence(to: 4)
        #expect(await waiting.value)
        #expect(store.pendingWaitCount == 0)
    }

    @Test func noPendingIntentIsIdleAtOnce() async {
        let store = Self.store()
        #expect(await store.waitIntentsIdle())
        #expect(store.pendingWaitCount == 0)
    }

    @Test func theSettlementOfTheLastIntentResumesTheIdleWait() async {
        let store = Self.store()
        let first = ClientTransactionID.generate()
        let second = ClientTransactionID.generate()
        store.intend(.renameWorkspace(key: Self.key, name: "two"), transaction: first)
        store.intend(.renameWorkspace(key: Self.key, name: "three"), transaction: second)
        let idle = Task { await store.waitIntentsIdle() }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1)
        store.rejectIntent(first)
        #expect(store.pendingWaitCount == 1, "the idle wait ended with an intent still pending")
        store.noteSettled(second, at: 4)
        #expect(store.pendingWaitCount == 1, "an intent whose sequence was not applied counted as settled")
        store.advanceAppliedSequence(to: 4)
        #expect(await idle.value)
        #expect(store.pendingIntents.isEmpty)
        #expect(store.pendingWaitCount == 0)
    }

    @Test func cancellingTheIdleWaitReturnsFalse() async {
        let store = Self.store()
        store.intend(.renameWorkspace(key: Self.key, name: "two"), transaction: .generate())
        let idle = Task { await store.waitIntentsIdle() }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1, "the idle wait was not parked before the cancel")
        idle.cancel()
        #expect(await idle.value == false)
        for _ in 0..<100 where store.pendingWaitCount > 0 { await Task.yield() }
        #expect(store.pendingWaitCount == 0)
    }

    @Test func settleWaitsForTheSequenceThenTheIntents() async {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.renameWorkspace(key: Self.key, name: "two"), transaction: transaction)
        let epoch = store.connectionEpoch
        let settling = Task { await store.settle(through: 2, since: epoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1)
        store.noteSettled(transaction, at: 3)
        store.advanceAppliedSequence(to: 2)
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1, "settle ended with an intent pending")
        store.advanceAppliedSequence(to: 3)
        #expect(await settling.value == [])
    }

    /// The caller reads the epoch with the barrier's sequence: a connection change before settle runs is not
    /// hidden by the next connection's applied sequence passing the old barrier.
    @Test func settleAfterAConnectionChangeNamesTheConnection() async {
        let store = Self.store()
        let sequence: UInt64 = 6
        let epoch = store.connectionEpoch
        store.apply(.disconnected(reason: "socket closed"))
        store.advanceAppliedSequence(to: sequence + 1)
        #expect(await store.settle(through: sequence, since: epoch) == [.connection])
        #expect(store.pendingWaitCount == 0)
    }

    @Test func aCancelledSettleNamesWhatWasPending() async {
        let store = Self.store()
        store.intend(.renameWorkspace(key: Self.key, name: "two"), transaction: .generate())
        let epoch = store.connectionEpoch
        let settling = Task { await store.settle(through: 8, since: epoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1, "the settle was not parked before the cancel")
        settling.cancel()
        #expect(await settling.value == [.applied, .intents])
    }

    /// Correctness only: 1,000 settles in a row each resume on the advance that reaches them and leave no
    /// continuation behind. No latency is measured here; the fleet p99 against settleMaxMs needs
    /// p15-oracle-031's `debug.oracle.settle` and has not run.
    @Test func aThousandSettlesInARowEachEndOnTheirAdvance() async {
        let store = Self.store()
        for sequence in UInt64(1)...1_000 {
            let epoch = store.connectionEpoch
            let settling = Task { await store.settle(through: sequence, since: epoch) }
            await Self.park(store, waits: 1)
            store.advanceAppliedSequence(to: sequence)
            #expect(await settling.value == [])
        }
        #expect(store.pendingWaitCount == 0)
    }

    /// The oracle's settle waits on the connection change while the daemon cannot answer its sync.
    @Test func aConnectionChangeResumesTheConnectionWait() async {
        let store = Self.store()
        let epoch = store.connectionEpoch
        let waiting = Task { await store.waitConnectionChange(since: epoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1)
        store.apply(.disconnected(reason: "daemon restart"))
        #expect(await waiting.value)
        #expect(store.pendingWaitCount == 0)
        #expect(await store.waitConnectionChange(since: epoch), "an epoch that already moved waited")
    }

    @Test func cancellingTheConnectionWaitReturnsFalse() async {
        let store = Self.store()
        let waiting = Task { await store.waitConnectionChange(since: store.connectionEpoch) }
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1, "the connection wait was not parked before the cancel")
        waiting.cancel()
        #expect(await waiting.value == false)
        for _ in 0..<100 where store.pendingWaitCount > 0 { await Task.yield() }
        #expect(store.pendingWaitCount == 0)
    }

    /// The settle's pending list names an intent by its case, never by its payload (a tab or workspace name).
    @Test func anIntentsCaseNameCarriesNoPayload() {
        #expect(Intent.renameWorkspace(key: Self.key, name: "private").caseName == "renameWorkspace")
        #expect(Intent.closeTabs(surfaces: []).caseName == "closeTabs")
    }
}

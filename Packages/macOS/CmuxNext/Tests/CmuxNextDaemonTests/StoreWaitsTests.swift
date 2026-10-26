import Testing
@testable import CmuxNextDaemon

/// The oracle's settle waits (p15-oracle-029): `waitApplied(atLeast:since:)` and `waitIntentsIdle()` are
/// continuations the store resumes from its own state changes (the applied sequence advancing, a connection
/// change, the overlay lift that empties the intent log), never an observation loop, a timer or a poll; a
/// cancelled wait resumes and leaves no continuation behind.
@MainActor
struct StoreWaitsTests {
    private static let workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "w1"), name: "one")

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        return store
    }

    /// Runs the main actor until `task` is parked on its continuation (each yield lets it run one step).
    private static func park(_ store: DaemonStore, waits count: Int) async {
        for _ in 0..<100 where store.pendingWaitCount < count { await Task.yield() }
    }

    @Test func aReachedSequenceReturnsAtOnce() async {
        let store = Self.store()
        store.advanceAppliedSequence(to: 7)
        #expect(await store.waitApplied(atLeast: 5) == .reached)
        #expect(await store.waitApplied(atLeast: 7) == .reached)
        #expect(store.pendingWaitCount == 0)
    }

    @Test func theAppliedSequenceAdvancingResumesTheWait() async {
        let store = Self.store()
        let waiting = Task { await store.waitApplied(atLeast: 3) }
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
        _ = DaemonConnectionChange.disconnected("socket closed").apply(to: store)
        #expect(await waiting.value == .connectionChanged)
        #expect(await store.waitApplied(atLeast: 1, since: epoch) == .connectionChanged, "an old epoch waited")
        #expect(store.pendingWaitCount == 0)
    }

    @Test func cancellingTheWaitResumesItAndDropsTheContinuation() async {
        let store = Self.store()
        let waiting = Task { await store.waitApplied(atLeast: 50) }
        await Self.park(store, waits: 1)
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        for _ in 0..<100 where store.pendingWaitCount > 0 { await Task.yield() }
        #expect(store.pendingWaitCount == 0)
        #expect(store.sequenceWaits.isEmpty, "the cancelled wait kept its stage read-your-writes mark")
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
        store.intend(.renameWorkspace(key: Self.workspace.key, name: "two"), transaction: first)
        store.intend(.renameWorkspace(key: Self.workspace.key, name: "three"), transaction: second)
        let idle = Task { await store.waitIntentsIdle() }
        await Self.park(store, waits: 1)
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
        store.intend(.renameWorkspace(key: Self.workspace.key, name: "two"), transaction: .generate())
        let idle = Task { await store.waitIntentsIdle() }
        await Self.park(store, waits: 1)
        idle.cancel()
        #expect(await idle.value == false)
        for _ in 0..<100 where store.pendingWaitCount > 0 { await Task.yield() }
        #expect(store.pendingWaitCount == 0)
    }

    @Test func settleWaitsForTheSequenceThenTheIntents() async {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.renameWorkspace(key: Self.workspace.key, name: "two"), transaction: transaction)
        let settling = Task { await store.settle(through: 2) }
        await Self.park(store, waits: 1)
        store.noteSettled(transaction, at: 3)
        store.advanceAppliedSequence(to: 2)
        await Self.park(store, waits: 1)
        #expect(store.pendingWaitCount == 1, "settle ended with an intent pending")
        store.advanceAppliedSequence(to: 3)
        #expect(await settling.value == [])
    }

    @Test func aCancelledSettleNamesWhatWasPending() async {
        let store = Self.store()
        store.intend(.renameWorkspace(key: Self.workspace.key, name: "two"), transaction: .generate())
        let settling = Task { await store.settle(through: 8) }
        await Self.park(store, waits: 1)
        settling.cancel()
        #expect(await settling.value == [.applied, .intents])
    }

    /// 1,000 waits in a row each resume on the advance that reaches them, in the same turn (the settle loop's
    /// shape on the fleet, minus the app).
    @Test func aThousandWaitsEachResumeOnTheirAdvance() async {
        let store = Self.store()
        for sequence in UInt64(1)...1_000 {
            let waiting = Task { await store.waitApplied(atLeast: sequence) }
            await Self.park(store, waits: 1)
            store.advanceAppliedSequence(to: sequence)
            #expect(await waiting.value == .reached)
        }
        #expect(store.pendingWaitCount == 0)
    }
}

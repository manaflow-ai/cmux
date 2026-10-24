import Foundation
import Testing
@testable import CmuxNextDaemon

/// The read-your-writes wait (`DaemonStore.appliedThrough(_:since:)`) says whether it held, through the paths
/// production takes. It holds once the store reached the sequence. A drop the daemon's stream reports comes
/// after every event routed before it (its sequence is the connection's last index), so a wait for those events
/// holds when the drop applies: they did apply. It does not hold when the connection ends with no such event:
/// the store marks it failed while it runs (a Cloud link that ended, `CloudMachineSession.showEnded`), or its
/// run ends (`close()` finishes the event stream with no envelope). Nothing newer applies for that connection,
/// so the wait must end, not held, instead of waiting for the next connect. No sequence (a connection that lost
/// `ready`) proves nothing. Each wait starts before the end arrives.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppliedThroughTests {
    /// A sequence of the store's first connection (serial 1) that the store has not reached.
    private static let pending = DaemonEventEnvelope.sequence(serial: 1, index: 5)

    /// A connection the store can mirror without a daemon: never started, so `close()` finishes its event
    /// stream with no envelope.
    private static func unstartedConnection() -> DaemonConnection {
        DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/tmp/cnd-applied-\(UUID().uuidString.prefix(8)).sock"))
    }

    @Test func aConnectionMarkedFailedDuringTheWaitIsNotAHeldBarrier() async {
        let store = DaemonStore()
        let connection = Self.unstartedConnection()
        let running = Task { await store.run(connection: connection) }
        await Task.yield()
        #expect(store.driver != nil, "the store mirrors the connection")
        let epoch = store.connectionEpoch
        let waiting = Task { await store.appliedThrough(Self.pending, since: epoch) }
        await Task.yield()
        #expect(store.appliedWaiters.count == 1, "the wait is inside the store before the end")
        store.markFailed("the link ended")
        #expect(await waiting.value == false, "a connection marked failed counted as a held barrier")
        await connection.close()
        await running.value
    }

    @Test func aRunEndedByCloseDuringTheWaitIsNotAHeldBarrier() async {
        let store = DaemonStore()
        let connection = Self.unstartedConnection()
        let running = Task { await store.run(connection: connection) }
        await Task.yield()
        #expect(store.driver != nil, "the store mirrors the connection")
        let epoch = store.connectionEpoch
        let waiting = Task { await store.appliedThrough(Self.pending, since: epoch) }
        await Task.yield()
        #expect(store.appliedWaiters.count == 1, "the wait is inside the store before the end")
        await connection.close()
        await running.value
        #expect(await waiting.value == false, "a closed connection counted as a held barrier")
    }

    @Test func aDropAfterTheRoutedEventsHolds() async {
        let store = DaemonStore()
        let epoch = store.connectionEpoch
        let waiting = Task { await store.appliedThrough(Self.pending, since: epoch) }
        await Task.yield()
        #expect(store.appliedWaiters.count == 1, "the wait is inside the store before the drop")
        let drop = DaemonEventEnvelope.sequence(serial: 1, index: DaemonEventEnvelope.lastIndex)
        store.apply(batch: [DaemonEventEnvelope(sequence: drop, event: .disconnected(reason: "socket closed"))])
        #expect(await waiting.value, "the events routed before the drop applied, so the wait holds")
        #expect(store.connectionState == .disconnected("socket closed"))
    }

    /// The connection changed between reading the sequence and waiting (here a drop of the store's connection
    /// before a wait for a later one): not held, at once.
    @Test func aConnectionChangeBeforeTheWaitIsNotAHeldBarrier() async {
        let store = DaemonStore()
        let epoch = store.connectionEpoch
        let drop = DaemonEventEnvelope.sequence(serial: 1, index: DaemonEventEnvelope.lastIndex)
        store.apply(batch: [DaemonEventEnvelope(sequence: drop, event: .disconnected(reason: "socket closed"))])
        #expect(await store.appliedThrough(DaemonEventEnvelope.sequence(serial: 2, index: 5), since: epoch) == false)
    }

    /// Reopen's undo watch is cancelled by the next reopen: the wait ends at once, not held, and leaves no waiter.
    @Test func aCancelledWaitEndsNotHeld() async {
        let store = DaemonStore()
        let epoch = store.connectionEpoch
        let waiting = Task { await store.appliedThrough(Self.pending, since: epoch) }
        await Task.yield()
        #expect(store.appliedWaiters.count == 1)
        waiting.cancel()
        #expect(await waiting.value == false)
        #expect(store.appliedWaiters.isEmpty, "a cancelled wait left its waiter behind")
    }

    @Test func noSequenceIsNotAHeldBarrier() async {
        let store = DaemonStore()
        #expect(await store.appliedThrough(nil, since: store.connectionEpoch) == false)
    }

    @Test func aStoreAlreadyPastTheSequenceHoldsAtOnce() async {
        let store = DaemonStore()
        store.appliedSequence = 7
        #expect(await store.appliedThrough(5, since: store.connectionEpoch))
        #expect(await store.appliedThrough(7, since: store.connectionEpoch))
    }
}

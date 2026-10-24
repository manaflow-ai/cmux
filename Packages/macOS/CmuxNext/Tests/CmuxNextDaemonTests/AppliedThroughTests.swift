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
        #expect(store.appliedWaiters.isEmpty, "a connection marked failed left the wait waiting")
        // Cancelled before it is awaited, so a wait that outlives the end fails the check above instead of
        // hanging the run (an unstructured task's value does not end on the time limit's cancellation).
        waiting.cancel()
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
        #expect(store.appliedWaiters.isEmpty, "a run ended by close() left the wait waiting")
        waiting.cancel()
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

    /// A reconnect of the same connection object: the sequence read after the reply is the next link's
    /// (serial 2) and the store applies link 1's drop after the wait began. That drop ends link 1's waits only;
    /// the wait for link 2's sequence holds once the store reaches it (the new link's snapshot).
    @Test func aDropOfTheLastLinkKeepsAWaitForTheNextLinksSequence() async {
        let store = DaemonStore()
        let epoch = store.connectionEpoch
        let next = DaemonEventEnvelope.sequence(serial: 2, index: 5)
        let waiting = Task { await store.appliedThrough(next, since: epoch) }
        await Task.yield()
        #expect(store.appliedWaiters.count == 1, "the wait is inside the store before the drop")
        let drop = DaemonEventEnvelope.sequence(serial: 1, index: DaemonEventEnvelope.lastIndex)
        store.apply(batch: [DaemonEventEnvelope(sequence: drop, event: .disconnected(reason: "socket closed"))])
        #expect(store.appliedWaiters.count == 1, "link 1's drop ended a wait for link 2's sequence")
        store.advanceAppliedSequence(to: next)
        #expect(store.appliedWaiters.isEmpty, "the store reached the sequence but the wait still waits")
        waiting.cancel()
        #expect(await waiting.value, "a wait for the next link's sequence did not hold once the store reached it")
    }

    /// A snapshot that fails past its retry budget leaves the store below the sequence until the next daemon
    /// event, which an idle daemon never sends: the wait ends then, not held, instead of keeping (say) close
    /// workspace's lane busy. A wait taken while the store has given up asks for one snapshot, and ends not held
    /// when that fails too.
    @Test func aWaitTheStoreGaveUpCatchingUpOnEndsNotHeld() async {
        let store = DaemonStore()
        let connection = Self.unstartedConnection()
        let running = Task { await store.run(connection: connection) }
        await Task.yield()
        #expect(store.driver != nil, "the store mirrors the connection")
        _ = store.apply(.connected(DaemonIdentity(generation: "resync-spent"), generationChanged: true))
        // No timed retry: the first failed snapshot spends the budget (the connection never started, so every
        // snapshot fails at once).
        store.resyncPacer = RetryPacer(RetryPolicy(initial: .milliseconds(1), maximum: .milliseconds(1), timedRetries: 0))
        let epoch = store.connectionEpoch
        let waiting = Task { await store.appliedThrough(Self.pending, since: epoch) }
        await Task.yield()
        #expect(store.appliedWaiters.count == 1, "the wait is inside the store before the snapshot fails")
        await store.refresh()
        #expect(store.needsResync, "the snapshot's retry budget is spent")
        #expect(store.appliedWaiters.isEmpty, "a wait the store gave up on still waits for an event")
        waiting.cancel()
        #expect(await waiting.value == false, "a wait the store gave up on counted as held")

        let later = Task { await store.appliedThrough(Self.pending, since: store.connectionEpoch) }
        await Task.yield()
        #expect(store.isResyncing, "a wait taken while the store has given up did not ask for a snapshot")
        await store.refresh()
        #expect(store.appliedWaiters.isEmpty, "a wait taken while the store has given up still waits")
        later.cancel()
        #expect(await later.value == false)
        await connection.close()
        await running.value
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

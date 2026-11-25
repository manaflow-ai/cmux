import Foundation
import Testing
@testable import CmuxNextDaemon

/// The read-your-writes wait (`DaemonStore.appliedThrough`) says whether it held: only a store that reached the
/// sequence holds every event the daemon emitted before a reply. A connection that drops during the wait ends it
/// without the events (the old wait returned as if they had applied), and no sequence (a connection that lost
/// `ready`) proves nothing. The every-action sweep's debug.closed_ids and the post-reply reads rely on it.
@MainActor
struct AppliedThroughTests {
    /// The caller reads the connection epoch with the sequence (one turn); a drop after that, before or during the
    /// wait, ends it as not held, whichever runs first.
    @Test func aDisconnectDuringTheWaitIsNotAHeldBarrier() async {
        let store = DaemonStore()
        let epoch = store.connectionEpoch
        let waiting = Task { await store.appliedThrough(5, since: epoch) }
        _ = DaemonConnectionChange.disconnected("socket closed").apply(to: store)
        #expect(await waiting.value == false, "a dropped connection counted as a held barrier")
        #expect(store.appliedSequence < 5)
    }

    /// The store's catch-up stopped (#32408): its snapshot retries are spent and it waits for the next daemon event
    /// to resync (`needsResync`), and none comes, because the caller that waits is what would make the daemon send
    /// one. The wait must end, as not held, instead of waiting forever: a classic upgrade of 512 workspaces froze at
    /// 130 for ten minutes in this state. Bounded by the store's own state, not by a clock.
    @Test(.timeLimit(.minutes(1))) func aStoreThatStoppedCatchingUpEndsTheWait() async {
        let store = DaemonStore()
        store.needsResync = true
        #expect(await store.appliedThrough(5, since: store.connectionEpoch) == false)
        #expect(store.appliedSequence < 5)
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

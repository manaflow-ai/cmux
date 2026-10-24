import Foundation
import Testing
@testable import CmuxNextDaemon

/// The wait for the session state's first snapshot (`DaemonStore.sessionStateResolved()`, which the sync
/// barrier and the incognito flags wait on) never outlives its connection. A run that `close()` ends before
/// the first `session.events` snapshot arrives (a shutdown, Quit, a removed machine) delivers no envelope and
/// changes no connection state: the wait must still end, through the same connection-end facts that end the
/// read-your-writes wait.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct SessionStateResolvedTests {
    /// Whether the waiting task got past the wait (it sets this right after the wait returns).
    @MainActor private final class Ended {
        var value = false
    }

    @Test func aRunEndedByCloseEndsTheWait() async {
        let store = DaemonStore()
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/tmp/cnd-session-\(UUID().uuidString.prefix(8)).sock"))
        let running = Task { await store.run(connection: connection) }
        await Task.yield()
        #expect(store.driver != nil, "the store mirrors the connection")
        #expect(!store.session.known)
        let ended = Ended()
        let waiting = Task {
            _ = await store.sessionStateResolved()
            ended.value = true
        }
        await Task.yield()
        #expect(!ended.value, "the wait returned before the session state resolved")
        await connection.close()
        await running.value
        // The ended wait's task runs before the test's next turn on the main actor.
        await Task.yield()
        #expect(ended.value, "a run ended by close() left the session-state wait waiting")
        // Cancelled before it is awaited, so a wait that outlives the end fails the check above instead of
        // hanging the run.
        waiting.cancel()
        await waiting.value
    }
}

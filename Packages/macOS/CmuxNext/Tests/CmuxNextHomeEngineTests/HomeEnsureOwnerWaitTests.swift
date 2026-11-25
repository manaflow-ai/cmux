import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// CMUX-571: the Chief owner's connect restarted a Home ensure that was waiting for that very owner, and a fresh
/// launch's Home page came 1.4-1.7 s later than it could (HomeEnsureOwnerWait's doc). The connect of the owner an
/// ensure waits for, or already goes on with, lets it go on; every other connect restarts it, as before.
@MainActor
struct HomeEnsureOwnerWaitTests {
    private static func connection() -> DaemonConnection {
        DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/tmp/cmux-home-ensure-owner-\(UUID().uuidString).sock"))
    }

    /// An owner that never serves conversations here (never started): the wait stays on it until cancelled.
    private static func idleOwner() -> ChiefConversationOwner {
        ChiefConversationOwner(home: ChiefHome(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                               isolated: true))
    }

    @Test func anEnsureWaitingForTheOwnerIsNotRestartedByItsConnect() async {
        let wait = HomeEnsureOwnerWait()
        let waiting = Task { await wait.connection(of: Self.idleOwner(), generation: 3) }
        await Task.yield()
        while wait.step == nil { await Task.yield() }
        #expect(wait.follows(current: 3, connected: Self.connection()), "the owner's connect restarted the ensure waiting for it")
        #expect(!wait.follows(current: 4, connected: Self.connection()), "an older ensure's wait kept a newer one from running")
        waiting.cancel()
        wait.end(3)
        #expect(wait.step == nil)
        #expect(!wait.follows(current: 3, connected: Self.connection()), "an ended ensure still holds back a restart")
    }

    @Test func noEnsureOnTheOwnerRestarts() {
        #expect(!HomeEnsureOwnerWait().follows(current: 1, connected: Self.connection()))
    }

    @Test func endingAnOlderEnsureKeepsTheNewerOnesWait() async {
        let wait = HomeEnsureOwnerWait()
        let waiting = Task { await wait.connection(of: Self.idleOwner(), generation: 5) }
        while wait.step == nil { await Task.yield() }
        wait.end(4)
        #expect(wait.step?.generation == 5)
        waiting.cancel()
    }
}

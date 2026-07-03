@testable import CmuxControlSocket
import Testing

// The pending-recovery signal the activation heal reads before it stands down.
// Its two published inputs (`pendingRearmGeneration`, `listenerReadSourceSuspended`)
// are set on the main actor, but the accept queue latches the in-flight recovery
// hop before dispatching the task that sets them -- a leading-edge window that
// must also count as pending, or an activation landing in it restarts over the
// scheduled backoff and resets the accept-failure streak (#6406 review). Forcing
// a real accept(2) failure is impractical in-process (see the rearm suite note),
// so the latch is seeded directly to pin the generation-scoped contract.
@MainActor
@Suite("SocketControlServer pending accept recovery")
struct SocketControlServerPendingRecoveryTests {
    @Test func inFlightRecoveryHopForLiveGenerationCountsAsPending() throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))

        // A freshly started, idle listener has no recovery pending.
        #expect(!server.hasPendingAcceptRecovery)

        let liveGeneration = server.activeListenerGeneration

        // Leading edge of accept-failure recovery: the hop is latched for the
        // live generation before the rearm/suspend flags are published. The
        // pending signal must already report recovery so the heal defers.
        server.acceptRecovery.withLock { recovery in
            recovery.generation = liveGeneration
            recovery.recoveryHopInFlight = true
        }
        #expect(server.hasPendingAcceptRecovery)

        // A hop latched for a superseded generation is a stale drain from a
        // listener that has since been replaced; it must not block the heal.
        server.acceptRecovery.withLock { recovery in
            recovery.generation = liveGeneration &+ 1
            recovery.recoveryHopInFlight = true
        }
        #expect(!server.hasPendingAcceptRecovery)

        // Once the hop clears, the signal falls back to false.
        server.acceptRecovery.withLock { recovery in
            recovery.generation = liveGeneration
            recovery.recoveryHopInFlight = false
        }
        #expect(!server.hasPendingAcceptRecovery)
    }
}

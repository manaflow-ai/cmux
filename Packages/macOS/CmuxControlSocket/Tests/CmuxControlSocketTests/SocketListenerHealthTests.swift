import Testing

@testable import CmuxControlSocket

@Suite struct SocketListenerHealthTests {
    @Test func failureSignalsAreEmptyWhenHealthy() {
        let health = SocketListenerHealth(
            isRunning: true,
            acceptLoopAlive: true,
            socketPathMatches: true,
            socketPathExists: true,
            socketPathOwnedByListener: true
        )
        #expect(health.isHealthy)
        #expect(health.failureSignals.isEmpty)
    }

    @Test func failureSignalsIncludeAllDetectedProblems() {
        let health = SocketListenerHealth(
            isRunning: false,
            acceptLoopAlive: false,
            socketPathMatches: false,
            socketPathExists: false,
            socketPathOwnedByListener: false
        )
        #expect(!health.isHealthy)
        #expect(
            health.failureSignals
                == ["not_running", "accept_loop_dead", "socket_path_mismatch", "socket_missing"]
        )
    }

    @Test func identityMismatchIsReportedSeparately() {
        let health = SocketListenerHealth(
            isRunning: true,
            acceptLoopAlive: true,
            socketPathMatches: true,
            socketPathExists: true,
            socketPathOwnedByListener: false
        )
        #expect(!health.isHealthy)
        #expect(health.failureSignals == ["socket_identity_mismatch"])
    }

    @Test func probeInputResolvesFilesystemIdentityOffTheServerReference() {
        let probe = SocketListenerHealthProbeInput(
            isRunning: false,
            acceptLoopAlive: false,
            listenerSocketPath: "/tmp/cmux-listener",
            expectedSocketPath: "/tmp/cmux-listener",
            boundSocketPathIdentity: SocketPathIdentity(device: 1, inode: 2)
        )

        let health = probe.resolve(using: SocketTransport())

        #expect(!health.isHealthy)
        #expect(health.failureSignals.contains("not_running"))
        #expect(health.failureSignals.contains("socket_missing"))
    }
}

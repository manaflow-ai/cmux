import Testing
@testable import CmuxNextDaemon

struct DaemonConnectionStartupCloseTests {
    @Test func closeBeforeInitialTaskRunsNeverInvokesEndpointProvider() async throws {
        let probe = StartupEndpointProbe()
        let connection = DaemonConnection(endpointProvider: {
            await probe.recordCall()
            throw DaemonError.launchFailed("unexpected endpoint call after close")
        })
        // The actor schedules its initial task and closes without suspending, making
        // close-before-connectOnce deterministic rather than relying on task timing.
        let attempt = try await connection.closeBeforeInitialAttemptRuns()
        _ = try? await attempt.value
        #expect(await probe.calls == 0)
        #expect(await connection.serial == 0, "a closed connection began a handshake")
        #expect(await connection.isReady == false)
        await connection.closeAndWait()
    }
}

private actor StartupEndpointProbe {
    var calls = 0
    func recordCall() { calls += 1 }
}

private extension DaemonConnection {
    func closeBeforeInitialAttemptRuns() throws -> Task<DaemonIdentity, any Error> {
        let attempt = try beginInitialAttempt()
        close()
        return attempt
    }
}

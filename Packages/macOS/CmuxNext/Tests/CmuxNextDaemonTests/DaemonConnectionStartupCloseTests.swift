import Testing
@testable import CmuxNextDaemon

struct DaemonConnectionStartupCloseTests {
    @Test func closeImmediatelyAfterStartDoesNotBeginHandshake() async throws {
        let probe = StartupEndpointProbe()
        let connection = DaemonConnection(endpointProvider: {
            await probe.recordCall()
            throw DaemonError.launchFailed("unexpected endpoint call after close")
        })
        // start() schedules its initial task before suspending. Closing in the next
        // actor turn must prevent that task from entering connectOnce.
        let started = Task { try await connection.start() }
        await connection.closeAndWait()
        _ = try? await started.value
        #expect(await probe.calls == 0)
        #expect(await connection.serial == 0, "a closed connection began a handshake")
        #expect(await connection.isReady == false)
    }
}

private actor StartupEndpointProbe {
    var calls = 0
    func recordCall() { calls += 1 }
}

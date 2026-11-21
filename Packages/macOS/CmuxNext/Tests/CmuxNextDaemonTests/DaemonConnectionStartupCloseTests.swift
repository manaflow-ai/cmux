import Foundation
import Testing
@testable import CmuxNextDaemon

struct DaemonConnectionStartupCloseTests {
    @Test func reconnectFromWaitingPhaseStartsAnotherAttempt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-reconnect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let wake = RetryWake(owner: "DaemonConnectionStartupCloseTests")
        let calls = CallCounter()
        let bridge = DaemonBridge.fakePython(["-c", Self.reconnectScript, file.path])
        let connection = DaemonConnection(
            configuration: .init(requiredCapabilities: [], retry: .init(initial: .milliseconds(1), maximum: .milliseconds(10), timedRetries: 3), retryWake: wake),
            endpointProvider: {
                await calls.increment()
                return DaemonEndpoint(socketPath: "/tmp/cmux-reconnect-test.sock", bridge: bridge)
            })
        let first = try await connection.start()
        #expect(first.session == "reconnect-test")
        wake.fire()
        let deadline = ContinuousClock.now + .seconds(5)
        while await calls.value < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await calls.value >= 2, "waiting-phase reconnect never invoked the endpoint provider")
        await connection.closeAndWait()
    }

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

    private static let reconnectScript = #"""
    import json, os, sys, time
    path = sys.argv[1]
    count = int(open(path).read() or "0") if os.path.exists(path) else 0
    open(path, "w").write(str(count + 1))
    print("{\"ok\":true}", file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get("cmd")
        if command == "identify":
            data = {"app":"cmux-tui", "protocol":12, "generation":"reconnect-test", "session":"reconnect-test", "capabilities":[]}
        else:
            data = {}
        print(json.dumps({"id":frame.get("id"), "ok":True, "data":data}), flush=True)
        if count == 0 and command == "subscribe":
            time.sleep(0.05)
            sys.exit(0)
    """#

}

private actor StartupEndpointProbe {
    var calls = 0
    func recordCall() { calls += 1 }
}

private actor CallCounter {
    var value = 0
    func increment() { value += 1 }
}

private extension DaemonConnection {
    func closeBeforeInitialAttemptRuns() throws -> Task<DaemonIdentity, any Error> {
        let attempt = try beginInitialAttempt()
        close()
        return attempt
    }
}

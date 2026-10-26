import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A keyed browser-tab create asks again with its key after a missed deadline, a closed connection or no
/// connection (``NewFrontendBrowserTabRequest/send(on:)``). The last two fail at once, so before the retry had a
/// Backoff it sent the create again and again on the actor for the whole 10 s budget, a busy loop while the daemon
/// reconnects. Each such retry now waits one Backoff step, with Backoff's tolerance, on the connection's clock.
struct FrontendBrowserTabKeyedRetryBackoffTests {
    private static let script = #"""
    import json, sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    caps = ['frontend-browser-tabs-v1', 'frontend-browser-tab-keys-v1']
    for line in sys.stdin:
        frame = json.loads(line)
        data = {}
        if frame.get('cmd') == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'keyed-retry-test', 'capabilities': caps}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    @Test(.timeLimit(.minutes(1)))
    func aKeyedCreateWithNoConnectionWaitsABackoffStepInsteadOfSpinning() async throws {
        let clock = SleepRecordingClock()
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-keyed-retry-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), terminalEnvironment: nil),
            clock: clock)
        try await connection.start()
        // The identity stays after close: the create takes the keyed path, and each send fails with notConnected.
        await connection.close()

        let create = Task { try await connection.newFrontendBrowserTab(url: "http://127.0.0.1/webkit0", engine: .webkit, in: nil) }
        var retryWait: SleepRecordingClock.Sleep?
        // The connection's own 10 s healthy timer may sleep on the clock too; a retry step is below 1 s.
        for await sleep in clock.sleeps where sleep.delay < .seconds(1) {
            retryWait = sleep
            break
        }
        create.cancel()

        let wait = try #require(retryWait, "the retry slept on the connection's clock instead of sending again at once")
        #expect(wait.delay > .milliseconds(30) && wait.delay <= .milliseconds(60), "the first Backoff step, 50 ms +/- 20%: \(wait.delay)")
        #expect(wait.tolerance == Backoff.tolerance(for: .milliseconds(50)), "Backoff's tolerance, 8 ms")
        await #expect(throws: CancellationError.self) { try await create.value }
    }
}

/// Reports each sleep (its delay from now and its tolerance) on ``sleeps``, then suspends until the sleeping task is
/// cancelled: a test reads what the code asked of the clock without ever waking it.
private final class SleepRecordingClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant

    struct Sleep: Sendable {
        let delay: Duration
        let tolerance: Duration?
    }

    let sleeps: AsyncStream<Sleep>
    private let record: AsyncStream<Sleep>.Continuation

    init() {
        (sleeps, record) = AsyncStream.makeStream()
    }

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        record.yield(Sleep(delay: now.duration(to: deadline), tolerance: tolerance))
        // A stream that never yields ends when the task is cancelled.
        let (never, hold) = AsyncStream<Never>.makeStream()
        for await _ in never {}
        withExtendedLifetime(hold) {}
        throw CancellationError()
    }
}

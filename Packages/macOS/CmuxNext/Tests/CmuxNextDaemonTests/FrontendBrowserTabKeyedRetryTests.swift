import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A keyed browser-tab create asks again with its key after a lost connection or no connection
/// (``NewFrontendBrowserTabRequest/send(on:)``). Both fail at once, so the retry must wait for the event
/// that can make it succeed: the connection is ready again. Before, it sent the create again and again on
/// the actor for the whole 10 s budget (a busy loop that also kept the reconnect off the actor); then it
/// slept a Backoff step on the connection's clock while its budget ran on the wall clock (a tab late by up
/// to a step after the reconnect, and a create that never ends on a clock that does not move).
///
/// The connection's clock is a ManualClock that the tests never advance: a wait that needs a timer to fire
/// never ends, and a wall-clock 5 s limit turns that into a failure instead of a hang.
struct FrontendBrowserTabKeyedRetryTests {
    /// A daemon with keyed creates. Its first process exits on the first create (the daemon went away
    /// after it read the request); the next process, the reconnect, answers it.
    private static let script = #"""
    import json, os, sys
    marker = sys.argv[1]
    print('{"ok":true}', file=sys.stderr, flush=True)
    caps = ['frontend-browser-tabs-v1', 'frontend-browser-tab-keys-v1']
    for line in sys.stdin:
        frame = json.loads(line)
        data = {}
        command = frame.get('cmd')
        if command == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'keyed-retry-test', 'capabilities': caps}
        elif command == 'new-frontend-browser-tab':
            if not os.path.exists(marker):
                open(marker, 'w').close()
                os._exit(0)
            data = {'surface': 41, 'tab_resource_id': 'tab_%032x' % 41, 'replayed': False}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    private struct Timeout: Error {}

    private func connection(clock: ManualClock, wake: RetryWake? = nil, marker: String) -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, marker])
        // timedRetries 0: the reconnect waits for `wake` alone, never for a timer on the clock.
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-keyed-retry-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], retry: RetryPolicy(initial: .milliseconds(50), maximum: .seconds(1), timedRetries: 0),
                                 retryWake: wake, requestTimeout: .seconds(1), terminalEnvironment: nil),
            clock: clock)
    }

    /// The create's outcome within 5 s of wall time; `Timeout` when it is still waiting (it is then cancelled).
    private func outcome(of create: Task<NewFrontendBrowserTabRequest.Response, any Error>) async -> Result<NewFrontendBrowserTabRequest.Response, any Error> {
        do {
            return .success(try await Deadline(.seconds(5)).run("FrontendBrowserTabKeyedRetryTests") { try await create.value })
        } catch is Deadline.Exceeded {
            create.cancel()
            return .failure(Timeout())
        } catch {
            return .failure(error)
        }
    }

    @Test func aKeyedCreateOnAClosedConnectionFailsAtOnce() async throws {
        let clock = ManualClock()
        let marker = NSTemporaryDirectory() + "cmux-keyed-retry-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let connection = connection(clock: clock, marker: marker)
        try await connection.start()
        // The identity stays after close: the create takes the keyed path, and its send fails with notConnected.
        await connection.close()

        let create = Task { try await connection.newFrontendBrowserTab(url: "http://127.0.0.1/webkit0", engine: .webkit, in: nil) }
        let result = await outcome(of: create)

        #expect(throws: DaemonError.notConnected, "a closed connection never becomes ready: the create fails at once") { try result.get() }
        #expect(clock.sleepRequests.allSatisfy { $0.deadline.offset >= .seconds(1) },
                "no retry step slept on the clock: \(clock.sleepRequests)")
    }

    @Test func aKeyedCreateAsksAgainWhenTheConnectionIsReadyAgain() async throws {
        let clock = ManualClock()
        let marker = NSTemporaryDirectory() + "cmux-keyed-retry-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let (parks, parked) = AsyncStream<Void>.makeStream()
        let wake = RetryWake(owner: "FrontendBrowserTabKeyedRetryTests", probe: RetryWakeProbe(parked: { _ in parked.yield() }))
        let connection = connection(clock: clock, wake: wake, marker: marker)
        try await connection.start()

        let create = Task { try await connection.newFrontendBrowserTab(url: "http://127.0.0.1/webkit0", engine: .webkit, in: nil) }
        // The daemon exits on the create; the reconnect parks until an event. The event reconnects.
        var waits = parks.makeAsyncIterator()
        _ = await waits.next()
        wake.fire()
        let result = await outcome(of: create)
        await connection.close()

        let created = try result.get()
        #expect(created.surface == SurfaceID(rawValue: 41), "the reconnected daemon answers the keyed create")
        // The clock never moved: only the ready connection resumed the create. Its one timer is the budget.
        #expect(clock.sleepRequests.allSatisfy { $0.deadline.offset >= .seconds(1) },
                "no retry step slept on the clock: \(clock.sleepRequests)")
    }
}

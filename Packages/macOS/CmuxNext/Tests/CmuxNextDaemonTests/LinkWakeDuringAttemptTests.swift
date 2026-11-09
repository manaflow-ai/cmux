import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// cmuxterm-hq#7766 review F2: a connection over a link that redials by itself has no timer left
/// after its one attempt (``RetryPolicy/linkReconnect``). When the link reported connected
/// (``RetryWake/fire()``) while that attempt was still failing, the rebaseline after the failure
/// dropped the event, and the daemon stayed disconnected until app activation or a manual
/// Reconnect. An event that comes during an attempt now wakes the wait after it.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LinkWakeDuringAttemptTests {
    private final class Calls: Sendable {
        private let count = Mutex(0)
        /// Notes one endpoint call and returns its number (1-based).
        func hit() -> Int { count.withLock { $0 += 1; return $0 } }
        var value: Int { count.withLock { $0 } }
    }

    /// Serves the handshake, then exits shortly after: a connection that came up and dropped.
    private static let script = #"""
    import json, sys, time
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('cmd') == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'link-wake-test', 'capabilities': []}
        else:
            data = {}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
        if frame.get('cmd') == 'subscribe':
            time.sleep(0.3)
            sys.exit(0)
    """#

    @Test func theLinkReportingConnectedDuringAFailingReconnectWakesTheNextAttempt() async throws {
        let calls = Calls()
        let wake = RetryWake(owner: "LinkWakeDuringAttemptTests.reconnect")
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        let socket = "/tmp/cmux-link-wake-test-\(UUID().uuidString).sock"
        let connection = DaemonConnection(
            configuration: .init(requiredCapabilities: [], retry: .linkReconnect, retryWake: wake, requestTimeout: .seconds(5),
                                 spawnTimeout: .seconds(5), terminalEnvironment: nil)
        ) {
            switch calls.hit() {
            case 1: return DaemonEndpoint(socketPath: socket, bridge: bridge)
            case 2:
                // The link reports connected while this attempt is still failing.
                wake.fire()
                throw DaemonError.notConnected
            default: throw DaemonError.notConnected
            }
        }
        try await connection.start()
        try await Task.sleep(for: .seconds(3))
        await connection.close()
        #expect(calls.value == 3, "the connected edge during the failing attempt was lost (\(calls.value) endpoint calls)")
    }

    /// Review F1 (fc883e4): the pacer reset only after ten healthy seconds, so a second drop soon after a
    /// recovered one found the budget spent and waited for an event that a connected link never sends.
    @Test func eachDropGetsItsAttemptAlsoASecondDropSoonAfter() async throws {
        let calls = Calls()
        let wake = RetryWake(owner: "LinkWakeDuringAttemptTests.drops")
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        let socket = "/tmp/cmux-link-drops-test-\(UUID().uuidString).sock"
        let connection = DaemonConnection(
            configuration: .init(requiredCapabilities: [], retry: .linkReconnect, retryWake: wake, requestTimeout: .seconds(5),
                                 spawnTimeout: .seconds(5), terminalEnvironment: nil)
        ) {
            _ = calls.hit()
            return DaemonEndpoint(socketPath: socket, bridge: bridge)
        }
        try await connection.start()
        // Each connection drops 0.3 s after its handshake: the first drop's attempt connects, and so
        // must the second drop's, well within ten seconds.
        try await Task.sleep(for: .seconds(4))
        await connection.close()
        #expect(calls.value >= 3, "a second drop within 10 s got no attempt (\(calls.value) endpoint calls)")
    }

    @Test func theLinkReportingConnectedDuringAFailingFirstConnectWakesTheNextAttempt() async throws {
        let calls = Calls()
        let wake = RetryWake(owner: "LinkWakeDuringAttemptTests.first")
        let configuration = DaemonConnectionConfiguration(requiredCapabilities: [], retry: .linkReconnect, retryWake: wake,
                                                          requestTimeout: .seconds(5), spawnTimeout: .seconds(5), terminalEnvironment: nil)
        let task = Task {
            await DaemonStartup.shared.connect(policy: .linkFirstConnect, wake: wake, makeConnection: {
                DaemonConnection(configuration: configuration) {
                    if calls.hit() == 1 { wake.fire() }
                    throw DaemonError.notConnected
                }
            }, onFailure: { _ in })
        }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        _ = await task.value
        #expect(calls.value == 2, "the connected edge during the failing first attempt was lost (\(calls.value) endpoint calls)")
    }

    /// Without an event during the attempt the wait stays event-only (no timer, no extra attempt).
    @Test func noEventDuringTheAttemptMeansNoExtraAttempt() async throws {
        let calls = Calls()
        let wake = RetryWake(owner: "LinkWakeDuringAttemptTests.quiet")
        let configuration = DaemonConnectionConfiguration(requiredCapabilities: [], retry: .linkReconnect, retryWake: wake,
                                                          requestTimeout: .seconds(5), spawnTimeout: .seconds(5), terminalEnvironment: nil)
        let task = Task {
            await DaemonStartup.shared.connect(policy: .linkFirstConnect, wake: wake, makeConnection: {
                DaemonConnection(configuration: configuration) {
                    _ = calls.hit()
                    throw DaemonError.notConnected
                }
            }, onFailure: { _ in })
        }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        _ = await task.value
        #expect(calls.value == 1)
    }

    @Test func anEventBeforeTheMarkIsStillDropped() async {
        let wake = RetryWake(owner: "LinkWakeDuringAttemptTests.mark")
        wake.fire()
        let mark = wake.eventMark
        wake.rebaseline(keepingEventsAfter: mark)
        let quiet = await wake.awaitWake(delay: .milliseconds(200), clock: ContinuousClock())
        #expect(quiet == .timer, "an event from before the attempt woke the wait")
        wake.fire()
        wake.rebaseline(keepingEventsAfter: mark)
        let woke = await wake.awaitWake(delay: .seconds(5), clock: ContinuousClock())
        #expect(woke == .event, "an event during the attempt was dropped")
    }
}

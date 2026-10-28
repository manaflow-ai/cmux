import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Audit B14: an accepted quiet handoff holds every new request until the next daemon is ready. When the
/// next daemon never becomes ready (its exit or its start is stuck), a held request must end with a typed
/// failure within a few seconds; it used to wait 65 s in silence, then fail as not connected.
@Suite(.timeLimit(.minutes(1))) struct HandoffHoldLimitTests {
    /// The longest a request may wait for the next daemon once the running one accepted the handoff.
    static let bound: Duration = .seconds(5)

    /// A stand-in for cmux-tui on a bridge that answers `identify` and exits on `set-split-ratio` (the
    /// handoff's own request: the old daemon goes away). Nothing reconnects it in these tests.
    private static let script = #"""
    import json, os, sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        data = {}
        command = frame.get('cmd')
        if command == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'handoff-hold-limit', 'capabilities': []}
        elif command == 'set-split-ratio':
            os._exit(0)
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    @Test func aRequestHeldForANextDaemonThatNeverStartsFailsWithinTheBound() async throws {
        // The hold limit sleeps on a clock that only the test moves; the reconnect waits for a wake nothing fires.
        let clock = ManualClock()
        let (reconnectParks, reconnectParked) = AsyncStream<Void>.makeStream()
        let wake = RetryWake(owner: "HandoffHoldLimitTests", probe: RetryWakeProbe(parked: { _ in reconnectParked.yield() }))
        let (gateWaits, gateWaited) = AsyncStream<QuietHandoffGate.Wait>.makeStream()
        var configuration = DaemonConnectionConfiguration(
            requiredCapabilities: [], retry: RetryPolicy(initial: .milliseconds(50), maximum: .seconds(1), timedRetries: 0),
            healthyAfter: .seconds(600), retryWake: wake, terminalEnvironment: nil)
        configuration.handoffWaits = { gateWaited.yield($0) }
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-hold-limit-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: configuration, clock: clock)
        do {
            try await connection.start()
            let accepted = await connection.quietHandoff { () async -> Bool in
                _ = try? await connection.request(SetSplitRatioRequest(split: 1, ratio: 0.5))
                return true
            }
            #expect(accepted)
            // The old daemon is gone and nothing reconnects: the next daemon never becomes ready.
            var parks = reconnectParks.makeAsyncIterator()
            _ = await parks.next()
            #expect(connection.admittedConnection == nil)
            #expect(connection.handoffGate.isHolding, "the accepted handoff did not hold new requests")

            let held = Task { try await connection.request(SetSplitRatioRequest(split: 1, ratio: 0.25)) }
            var waits = gateWaits.makeAsyncIterator()
            let parked = await waits.next()
            #expect(parked == .request, "the request did not wait for the next daemon")
            // The connection's other timer (healthy) ended with the old daemon: the sleeper is the hold's limit.
            try await clock.waitForSleeper()
            clock.advance(by: Self.bound)

            // Past the bound the request must end by itself. The watchdog (wall clock) closes the connection,
            // which ends any hold, only when it did not.
            let watchdog = Task { () -> Bool in
                do { try await Task.sleep(for: .seconds(10)) } catch { return false }
                await connection.close()
                return true
            }
            let outcome = await held.result
            watchdog.cancel()
            let closedByWatchdog = await watchdog.value
            #expect(!closedByWatchdog,
                    "a request held by an accepted handoff was still waiting \(Self.bound) after it, with no next daemon")
            if case .success = outcome { Issue.record("the held request succeeded with no daemon to carry it") }
            if case .failure(let error) = outcome {
                #expect(error is DaemonError, "the held request ended with an untyped error: \(error)")
            }
            #expect(!connection.handoffGate.isHolding, "the hold outlived its bound")
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}

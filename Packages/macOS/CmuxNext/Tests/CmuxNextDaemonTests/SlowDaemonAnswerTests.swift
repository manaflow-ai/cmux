import Foundation
import Testing
@testable import CmuxNextDaemon

/// Leo, 2026-11-04, on "the app's calls to the daemon were timing out at 2 s": "shouldn't be this short. no reason for
/// this." A busy daemon answers late, not never: requests queued behind a 5-8 s journal step missed the 2 s default
/// (#34628) while the daemon still answered them. The default now waits as long as the heartbeat does before it calls
/// the daemon not answering.
@Suite struct SlowDaemonAnswerTests {
    /// Serves the handshake at once, then answers every later `identify` after `delay` seconds.
    private static let script = #"""
    import json, sys, time
    delay = float(sys.argv[1])
    identifies = 0
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('cmd') == 'identify':
            identifies += 1
            if identifies > 1:
                time.sleep(delay)
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'slow-answer-test', 'capabilities': []}
        else:
            data = {}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    @Test func theDefaultDeadlineWaitsForADaemonThatAnswersIn3Seconds() async throws {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, "3"])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-slow-answer-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        try await connection.start()
        let started = ContinuousClock.now
        do {
            let identity = try await connection.request(IdentifyRequest())
            #expect(identity.app == "cmux-tui")
            #expect(ContinuousClock.now - started >= .seconds(3))
        } catch {
            Issue.record("a daemon that answered in 3 s failed the request: \(error)")
        }
        await connection.close()
    }

    @Test func theDefaultDeadlineIsTheHeartbeatsWindow() {
        let configuration = DaemonConnectionConfiguration()
        #expect(DaemonConnection.defaultRequestTimeout >= configuration.heartbeat * configuration.heartbeatMisses)
        #expect(configuration.snapshotTimeout == DaemonConnection.defaultRequestTimeout)
    }
}

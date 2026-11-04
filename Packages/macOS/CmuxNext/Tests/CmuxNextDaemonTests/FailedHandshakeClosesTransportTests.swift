import Foundation
import Testing
@testable import CmuxNextDaemon

/// cmux NIGHTLY (2026-11-03) trapped in the allocator after about 14 hours: a reader thread was
/// appending to the `EventGate` of a connection whose handshake had failed. Under load the
/// daemon answered `identify` past the request deadline, so `connectOnce` threw, but the transport
/// stayed open: its reader thread kept running, the daemon (which had already taken the pipelined
/// `subscribe`) kept streaming events, and the gate, never opened, held every one. Each retry
/// leaked another reader and another growing buffer, about 20 of them at the crash.
///
/// A failed attempt now closes the transport it opened.
@Suite struct FailedHandshakeClosesTransportTests {
    /// Answers every command except `identify`, so the handshake times out with the socket open.
    /// Writes its pid first, so the test can see whether the app let go of it.
    private static let script = #"""
    import json, sys
    open(sys.argv[1], 'w').write(str(__import__('os').getpid()))
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('cmd') == 'identify':
            continue
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': {}}), flush=True)
    """#

    @Test func aTimedOutHandshakeClosesItsTransport() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-failed-handshake-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, pidFile])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-failed-handshake-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .milliseconds(300), spawnTimeout: .seconds(2),
                                 terminalEnvironment: nil))
        do {
            try await connection.start()
            Issue.record("a handshake with no identify reply started")
        } catch {}
        let pid = try #require(pid_t(String(contentsOfFile: pidFile, encoding: .utf8)))

        // The failed attempt's transport ends its bridge child; before the fix it stayed alive.
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let stillOpen = kill(pid, 0) == 0
        #expect(!stillOpen, "the failed handshake left its transport, and the daemon's events, open")
        if stillOpen { kill(pid, SIGKILL) }
        await connection.close()
    }
}

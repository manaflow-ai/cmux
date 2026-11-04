import Foundation
import Testing
@testable import CmuxNextDaemon

/// A keyed browser-tab create sent while the link to its daemon is down (#35878): it waits for the connection's connected
/// event and sends once when the link is up again, or fails at the request deadline. Before, it asked again at once on
/// every `notConnected`, a loop that never left the connection actor for its whole 10 s budget: the reconnect could not
/// run on that actor meanwhile, so the link stayed down, the create never reached the daemon and failed at the budget.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport (`frontend-browser-tab-keys-v1`, one tab per key,
/// as cmux-tui). Its first run answers, then exits on `test-exit` (the link drops); the connection's reconnect starts a
/// second run, which waits before it answers the handshake (`back`: 1.5 s, the link comes back; `gone`: it never does).
struct FrontendBrowserTabLinkDownTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-browser-creates"
    }

    private struct Exit: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-exit"
    }

    private static let script = #"""
    import json, os, sys, time
    mode, marker = sys.argv[1], sys.argv[2]
    relaunch = os.path.exists(marker)
    open(marker, 'a').close()
    print('{"ok":true}', file=sys.stderr, flush=True)
    if relaunch:
        time.sleep(1.5 if mode == 'back' else 30)
    creates, tabs = [], {}
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            caps = ['frontend-browser-tabs-v1', 'frontend-browser-tab-keys-v1']
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'link-down-test', 'capabilities': caps})
        elif command == 'new-frontend-browser-tab':
            creates.append(frame)
            key = frame.get('idempotency_key')
            replayed = key in tabs
            if not replayed:
                tabs[key] = 40 + len(tabs)
            reply(frame, {'surface': tabs[key], 'tab_resource_id': 'tab_%032x' % tabs[key], 'replayed': replayed})
        elif command == 'test-browser-creates':
            reply(frame, {'creates': creates, 'tabs': len(tabs)})
        elif command == 'test-exit':
            reply(frame, {})
            sys.exit(0)
        else:
            reply(frame, {})
    """#

    /// A connection to the scripted daemon in `mode`, whose deadline is `deadline`, and the link dropped: the daemon's
    /// first run exited, and the connection knows it.
    private func droppedLink(_ mode: String, deadline: Duration) async throws -> DaemonConnection {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-link-down-\(UUID().uuidString)").path
        let bridge = DaemonBridge.fakePython(["-c", Self.script, mode, marker])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-link-down-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: deadline, terminalEnvironment: nil))
        try await connection.start()
        _ = try await connection.request(Exit())
        var waited = 0
        while await connection.isReady, waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let dropped = await !connection.isReady
        try #require(dropped, "the link never dropped")
        return connection
    }

    /// The link comes back 1.5 s after the drop: the create goes out once it is up, and the daemon makes the one tab.
    @Test func aCreateSentWhileTheLinkIsDownGoesOnceWhenTheLinkIsBack() async throws {
        let connection = try await droppedLink("back", deadline: .seconds(10))
        let started = ContinuousClock.now
        let created = try await connection.newFrontendBrowserTab(url: "http://127.0.0.1/link-down", engine: .webkit, in: nil)
        let took = ContinuousClock.now - started
        let recorded = try await connection.request(Recorded())
        await connection.close()
        let creates = try #require(recorded["creates"]?.arrayValue)
        #expect(creates.count == 1, "the create reached the daemon \(creates.count) times, not once")
        #expect(created.surface == SurfaceID(rawValue: 40))
        #expect(took < .seconds(6), "the create waited \(took) for a link that came back 1.5 s after the drop")
    }

    /// The link never comes back: the create fails at the request deadline (2 s), not at its 10 s late-reply budget.
    @Test func aCreateWhoseLinkStaysDownFailsAtTheRequestDeadline() async throws {
        let connection = try await droppedLink("gone", deadline: .seconds(2))
        let started = ContinuousClock.now
        await #expect(throws: DaemonError.self) {
            try await connection.newFrontendBrowserTab(url: "http://127.0.0.1/link-down", engine: .webkit, in: nil)
        }
        let took = ContinuousClock.now - started
        await connection.close()
        #expect(took < .seconds(4), "the create failed \(took) after its start; the request deadline is 2 s")
    }
}

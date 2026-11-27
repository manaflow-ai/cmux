import Foundation
import Testing
@testable import CmuxNextDaemon

/// P0 on v2.2.9-opt (Lawrence, a 4 h session, 2026-10-30): "at some points I can no longer make new terminals via
/// Ctrl-`". Fleet repro (cmux17, cmux20, cmux21): Cmd-T, then Ctrl-`. The New Tab page's `new-conversation-tab` got
/// no reply for seconds, the `new-tab` behind it on the same connection missed the client's 5 s start deadline, and
/// the app took the Ctrl-` stand-in back (`rejectIntent`). No terminal, and the keys typed for it went to the old one.
/// A client clock decided whether the terminal exists (principled-audit R5).
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport. It answers the first `new-tab` only after its
/// own start delay, longer than the client's start deadline, as a busy cmux-tui does: the request is queued, the tab
/// is made, the reply comes late. cmux-tui does not replay a `new-tab` sent again, so the app must wait for that
/// reply (or the connection's end), never resend and never give up on its own clock.
struct NewTabLateStartTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-tabs"
    }

    private static let script = #"""
    import json, sys, threading
    print('{"ok":true}', file=sys.stderr, flush=True)
    tabs, lock = [], threading.Lock()
    caps = ['terminal-placement-env-v1', 'terminal-env-v1']
    def reply(frame, data):
        with lock:
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def made(frame):
        tabs.append(frame)
        reply(frame, {'surface': 10 + len(tabs), 'terminal_id': frame.get('terminal_id')})
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'new-tab-late-start-test', 'capabilities': caps})
        elif command == 'new-tab':
            # The tab is made after a start that outlasts the client's deadline (a busy daemon, a loaded host).
            threading.Timer(float(sys.argv[1]), made, args=(frame,)).start()
        elif command == 'test-tabs':
            reply(frame, {'tabs': tabs})
        else:
            reply(frame, {})
    """#

    /// The client's start deadline is 0.2 s; the daemon answers after 1.5 s.
    private func connection() -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, "1.5"])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-new-tab-late-start-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(5), spawnTimeout: .milliseconds(200),
                                 terminalEnvironment: nil))
    }

    @Test func aNewTabThatStartsLateIsWaitedForAndMadeOnce() async throws {
        let connection = connection()
        try await connection.start()
        var options = SpawnOptions(cwd: "/tmp")
        options.terminalID = TerminalID.generate()
        let created = try await connection.newTab(in: PaneID(rawValue: 3), options: options)
        let recorded = try await connection.request(Recorded())
        await connection.close()

        let tabs = try #require(recorded["tabs"]?.arrayValue)
        #expect(tabs.count == 1, "the late start is waited for: no second new-tab, no tab taken back")
        #expect(tabs.first?["terminal_id"]?.stringValue == options.terminalID?.rawValue, "the tab carries the stand-in's terminal id")
        #expect(created.surface == SurfaceID(rawValue: 11), "new-tab answers the tab the daemon made")
        #expect(created.terminalID == options.terminalID)
    }
}

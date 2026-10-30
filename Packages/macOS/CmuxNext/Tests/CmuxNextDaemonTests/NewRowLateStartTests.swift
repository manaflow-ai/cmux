import Foundation
import Testing
@testable import CmuxNextDaemon

/// P0 2026-10-30, review of fix/p0-new-terminal-always: a New Row's stand-in (an optimistic `new-row` under
/// `row-client-keys-v1`) still had the 5 s start deadline, so on a loaded host the row was taken back while cmux-tui
/// still made it, and the DEBUG R3 check stopped the app there. A keyed row now waits through a late start as a split
/// does: sent again under its client keys, which the daemon replays, until the reply.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport. It makes one row per client-minted `pane_id`
/// and its start ends once, `delay` after the first ask (longer than the client's start deadline); an ask after
/// that is replayed at once, as cmux-tui replays a keyed creation.
struct NewRowLateStartTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-rows"
    }

    private static let script = #"""
    import json, sys, threading, time
    print('{"ok":true}', file=sys.stderr, flush=True)
    rows, panes, lock, started = [], {}, threading.Lock(), None
    caps = ['terminal-placement-env-v1', 'terminal-env-v1', 'rows-v1', 'row-client-keys-v1']
    def reply(frame, data):
        with lock:
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def made(frame):
        key = frame.get('pane_id') or 'unkeyed-%d' % len(rows)
        with lock:
            replayed = key in panes
            if not replayed:
                panes[key] = 10 + len(panes)
        reply(frame, {'surface': panes[key], 'terminal_id': frame.get('terminal_id'), 'replayed': replayed})
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'new-row-late-start-test', 'capabilities': caps})
        elif command == 'new-row':
            rows.append(frame)
            # One start: it ends `delay` after the first ask; an ask after that is replayed at once.
            if started is None:
                started = time.time()
            threading.Timer(max(0.0, started + float(sys.argv[1]) - time.time()), made, args=(frame,)).start()
        elif command == 'test-rows':
            reply(frame, {'rows': rows, 'panes': len(panes)})
        else:
            reply(frame, {})
    """#

    @Test func aKeyedRowThatStartsLateIsWaitedForAndMadeOnce() async throws {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, "1.0"])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-new-row-late-start-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(5), spawnTimeout: .milliseconds(300),
                                 terminalEnvironment: nil))
        try await connection.start()
        var options = SpawnOptions(cwd: "/tmp")
        options.paneID = "pane_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        options.tabID = "tab_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        options.terminalID = TerminalID.generate()
        let created = try await RowCommands(connection).newRow(below: PaneID(rawValue: 3), height: 500, options: options)
        let recorded = try await connection.request(Recorded())
        await connection.close()

        #expect(created.surface == SurfaceID(rawValue: 10), "the row the daemon started late is the one returned")
        #expect(recorded["panes"]?.doubleValue == 1, "asking again under the client keys makes no second row")
        let rows = try #require(recorded["rows"]?.arrayValue)
        #expect(rows.allSatisfy { $0["pane_id"]?.stringValue == options.paneID }, "every request carries the stand-in's pane id")
    }
}

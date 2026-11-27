import Foundation
import Testing
@testable import CmuxNextDaemon

/// P0 2026-10-30, review of fix/p0-new-terminal-always: a New Row's stand-in (an optimistic `new-row` under
/// `row-client-keys-v1`) had the 5 s start deadline, so on a loaded host the row was taken back while cmux-tui still
/// made it. cmux-tui does not replay a `new-row` sent again: a second ask with the same `pane_id` is refused
/// `pane_id_exists` (resource_topology/client_ids.rs), so asking again would make the app take the row back on that
/// refusal. The row is sent once and waits for its reply or the connection's end.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport, modelled on cmux-tui: it makes the row after a
/// start longer than the client's start deadline, and refuses a second `new-row` with a `pane_id` it already holds.
struct NewRowLateStartTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-rows"
    }

    private static let script = #"""
    import json, sys, threading
    print('{"ok":true}', file=sys.stderr, flush=True)
    rows, panes, lock = [], {}, threading.Lock()
    # As cmux-tui advertises them (server/capabilities.rs): the app sends a row's client keys under split-client-keys-v1.
    caps = ['terminal-placement-env-v1', 'terminal-env-v1', 'rows-v1', 'split-client-keys-v1', 'row-client-keys-v1']
    def write(line):
        with lock:
            print(json.dumps(line), flush=True)
    def made(frame):
        with lock:
            panes[frame.get('pane_id')] = 10 + len(panes)
            surface = panes[frame.get('pane_id')]
        write({'id': frame.get('id'), 'ok': True, 'data': {'surface': surface, 'terminal_id': frame.get('terminal_id')}})
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            write({'id': frame.get('id'), 'ok': True, 'data': {'app': 'cmux-tui', 'protocol': 12,
                   'generation': 'new-row-late-start-test', 'capabilities': caps}})
        elif command == 'new-row':
            rows.append(frame)
            if any(r is not frame and r.get('pane_id') == frame.get('pane_id') for r in rows):
                write({'id': frame.get('id'), 'ok': False, 'error': 'pane_id_exists', 'code': 'pane_id_exists'})
                continue
            threading.Timer(float(sys.argv[1]), made, args=(frame,)).start()
        elif command == 'test-rows':
            write({'id': frame.get('id'), 'ok': True, 'data': {'rows': rows, 'panes': len(panes)}})
        else:
            write({'id': frame.get('id'), 'ok': True, 'data': {}})
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
        let rows = try #require(recorded["rows"]?.arrayValue)
        #expect(rows.count == 1, "cmux-tui refuses a new-row sent again; the late row is waited for, asked once")
        #expect(rows.first?["pane_id"]?.stringValue == options.paneID, "the request carries the stand-in's pane id")
        #expect(recorded["panes"]?.doubleValue == 1)
    }
}

import Foundation
import Testing
@testable import CmuxNextDaemon

/// HOT PATH AUDIT state (hpa-state, 2026-11-03): Move Tab to New Row read the daemon's whole tree
/// (`list-workspaces`, about 3.7 KB per workspace: 1.5 MB at 400) to find the row's pane, which `new-row`
/// already names in its reply (`pane`). It now reads no tree.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport. Like cmux-tui, it names the new row's
/// pane in the `new-row` reply, and it counts every `list-workspaces`.
struct MoveTabToNewRowTreeReadsTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-reads"
    }

    private static let script = #"""
    import json, sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    caps = ['rows-v1']
    reads, moves = 0, []
    def write(line):
        print(json.dumps(line), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            write({'id': frame.get('id'), 'ok': True, 'data': {'app': 'cmux-tui', 'protocol': 12,
                   'generation': 'move-tab-new-row-test', 'capabilities': caps}})
        elif command == 'list-workspaces':
            reads += 1
            write({'id': frame.get('id'), 'ok': True, 'data': {'workspaces': [{'id': 1, 'key': 'w', 'name': 'w',
                   'screens': [{'id': 1, 'panes': [{'id': 3, 'tabs': [{'surface': 30}]},
                                                   {'id': 9, 'tabs': [{'surface': 90}]}]}]}]}})
        elif command == 'new-row':
            write({'id': frame.get('id'), 'ok': True, 'data': {'surface': 90, 'pane': 9}})
        elif command == 'move-tab':
            moves.append(frame)
            write({'id': frame.get('id'), 'ok': True, 'data': {'surface': frame.get('surface'), 'pane': frame.get('pane')}})
        elif command == 'test-reads':
            write({'id': frame.get('id'), 'ok': True, 'data': {'reads': reads, 'moves': moves}})
        else:
            write({'id': frame.get('id'), 'ok': True, 'data': {}})
    """#

    @Test func aTabMovedToANewRowGoesToThePaneTheReplyNamesWithNoTreeRead() async throws {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-newrow-reads-\(UUID().uuidString.prefix(8)).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(5), spawnTimeout: .milliseconds(300),
                                 terminalEnvironment: nil))
        try await connection.start()
        try await RowCommands(connection).moveTab(SurfaceID(rawValue: 31), toNewRowBelow: PaneID(rawValue: 3), height: 500)
        let recorded = try await connection.request(Recorded())
        await connection.close()

        let moves = try #require(recorded["moves"]?.arrayValue)
        #expect(moves.first?["pane"]?.doubleValue == 9, "the tab went to the pane the new-row reply names")
        #expect(recorded["reads"]?.doubleValue == 0,
                "Move Tab to New Row read the whole tree \(recorded["reads"]?.doubleValue ?? -1) times; the reply names the pane")
    }
}

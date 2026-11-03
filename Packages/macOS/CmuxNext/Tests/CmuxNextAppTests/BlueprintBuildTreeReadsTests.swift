@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// HOT PATH AUDIT state (hpa-state, 2026-11-03): a workspace built from a blueprint (a layout template, a
/// classic session's workspace) read the whole tree (`list-workspaces`, about 3.7 KB per workspace: 1.5 MB at
/// 400) after each split, column and screen, only to find the pane it had just made. In the 512-workspace classic
/// upgrade (#32408, diag job 74a6b4ff) that was about 5 whole trees per workspace and the layout step grew from
/// 21 ms to 2,017 ms. The daemon names the new pane in its reply (`pane`); the build reads the tree twice, at its
/// start and for the split ids, whatever the blueprint's size.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport. Like cmux-tui, it names the new pane in
/// each creation's reply, and it counts every `list-workspaces`.
struct BlueprintBuildTreeReadsTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-reads"
    }

    private static let script = #"""
    import json, sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    panes = [{'id': 1, 'tabs': [{'surface': 100}]}]
    reads = 0
    def write(line):
        print(json.dumps(line), flush=True)
    def made(frame):
        surface = 100 + len(panes)
        pane = {'id': 1 + len(panes), 'tabs': [{'surface': surface}]}
        panes.append(pane)
        write({'id': frame.get('id'), 'ok': True, 'data': {'surface': surface, 'pane': pane['id']}})
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            write({'id': frame.get('id'), 'ok': True, 'data': {'app': 'cmux-tui', 'protocol': 12,
                   'generation': 'blueprint-tree-reads-test', 'capabilities': []}})
        elif command == 'list-workspaces':
            reads += 1
            write({'id': frame.get('id'), 'ok': True, 'data': {'workspaces': [
                {'id': 1, 'key': 'blueprint-ws', 'name': 'w', 'screens': [{'id': 1, 'panes': panes}]}]}})
        elif command in ('split', 'new-pane-right', 'new-pane'):
            made(frame)
        elif command == 'test-reads':
            write({'id': frame.get('id'), 'ok': True, 'data': {'reads': reads, 'panes': len(panes)}})
        else:
            write({'id': frame.get('id'), 'ok': True, 'data': {}})
    """#

    @Test func aBlueprintReadsTheTreeTwiceWhateverItsSize() async throws {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-blueprint-reads-\(UUID().uuidString.prefix(8)).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(5), spawnTimeout: .milliseconds(300),
                                 terminalEnvironment: nil))
        try await connection.start()
        let leaf = WorkspaceBlueprint.Node.pane([.terminal(cwd: "/tmp")])
        // Two columns; the first holds three splits: five panes made after the first.
        let first = WorkspaceBlueprint.Node.split(direction: .right, ratio: 0.5,
                                                  a: .split(direction: .down, ratio: 0.3, a: leaf, b: leaf),
                                                  b: .split(direction: .down, ratio: 0.6, a: leaf, b: leaf))
        let blueprint = WorkspaceBlueprint(name: "w", color: nil, icon: nil, screens: [
            WorkspaceBlueprint.Screen(name: nil, columns: [
                WorkspaceBlueprint.Column(width: nil, root: first),
                WorkspaceBlueprint.Column(width: nil, root: leaf),
            ]),
        ])
        let builder = WorkspaceBlueprintBuilder(connection: connection, key: WorkspaceKey(rawValue: "blueprint-ws"),
                                                browsers: false, defaultEngine: .webkit)
        try await builder.build(blueprint)
        let recorded = try await connection.request(Recorded())
        await connection.close()

        #expect(recorded["panes"]?.doubleValue == 5, "the build made its four panes and one column")
        #expect(recorded["reads"]?.doubleValue == 2,
                "the build read the whole tree \(recorded["reads"]?.doubleValue ?? -1) times; 2 (its start and the split ids) is the floor")
    }
}

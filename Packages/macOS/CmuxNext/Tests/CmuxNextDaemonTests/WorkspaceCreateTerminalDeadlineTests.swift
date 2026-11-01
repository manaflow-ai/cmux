import Foundation
import Testing
@testable import CmuxNextDaemon

/// base8 at 61ad0ed216f, StashTests on a loaded host: "timed out: workspace.create (no reply within
/// 2.0 seconds)". cmux-tui starts a workspace's first terminal inside the `workspace.create` effect
/// (effect_execution.rs), so a create with `initial_content: terminal` answers once that host is up,
/// as `new-tab` does. The app gave it the 2 s control-plane deadline, not the terminal start deadline
/// (`spawnTimeout`) every other terminal start has; the daemon still made the workspace after the
/// app gave up (the incognito window's create is the same call).
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport answers each
/// `workspace.create` after a delay longer than the connection's request deadline and shorter than
/// its terminal start deadline.
struct WorkspaceCreateTerminalDeadlineTests {
    private static let script = #"""
    import json, sys, time
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('cmd') == 'identify':
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': {'app': 'cmux-tui', 'protocol': 12,
                'generation': 'create-deadline-test', 'capabilities': []}}), flush=True)
        elif frame.get('operation') == 'workspace.create':
            time.sleep(1.5)  # the first terminal's host starts on a loaded machine
            terminal = frame['params'].get('initial_content') == 'terminal'
            value = {'workspace_id': 'ws_' + 'a' * 32}
            if terminal:
                value.update({'tab_id': 'tab_' + 'a' * 32, 'terminal_id': 'term_' + 'a' * 32})
            print(json.dumps({'protocol': 'cmux.protocol/2', 'type': 'response', 'id': frame.get('id'), 'ok': True,
                'result': {'value': value, 'revision': '1', 'replayed': False}}), flush=True)
        else:
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': {}}), flush=True)
    """#

    /// A connection whose request deadline (1 s) is shorter than the daemon's 1.5 s answer, and whose
    /// terminal start deadline (4 s) is longer.
    private func connection() -> DaemonConnection {
        let bridge = DaemonBridge.fakePython(["-c", Self.script])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-create-deadline-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), spawnTimeout: .seconds(4),
                                 terminalEnvironment: nil))
    }

    @Test func aCreateThatStartsATerminalHasTheTerminalStartDeadline() async throws {
        let connection = connection()
        try await connection.start()
        let created: StateResourceClient.CreatedWorkspace
        do {
            created = try await connection.state.createWorkspace(name: "late", ephemeral: false, terminal: true, focus: false)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
        #expect(created.terminalID?.rawValue == "term_" + String(repeating: "a", count: 32))
    }

    /// An empty create starts no terminal: it keeps the control-plane deadline.
    @Test func anEmptyCreateKeepsTheRequestDeadline() async throws {
        let connection = connection()
        try await connection.start()
        await #expect(throws: DaemonError.self) {
            try await connection.state.createWorkspace(name: "empty", ephemeral: false, terminal: false, focus: false)
        }
        await connection.close()
    }
}

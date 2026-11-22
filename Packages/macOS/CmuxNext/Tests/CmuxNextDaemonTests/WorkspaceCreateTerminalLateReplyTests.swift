import Foundation
import Testing
@testable import CmuxNextDaemon

/// cmux-tui starts a new workspace's terminal inside the `workspace.create` effect (effect_execution.rs) and answers
/// once its host is up: a new terminal (R3). base8 at 61ad0ed216f, StashTests on a loaded host: "timed out:
/// workspace.create (no reply within 2.0 seconds)", while the daemon still made the workspace; an incognito window's
/// create is the same call. The create must end on the daemon's answer, never on a client clock (principled-audit R5):
/// it is sent again under its first idempotency key, which the daemon replays.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport holds the first `workspace.create` reply until
/// the client acts: until a second create with the same idempotency key arrives. Then it answers both, the second as
/// a replay of the first (one workspace). An empty create's reply is held for good.
struct WorkspaceCreateTerminalLateReplyTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-creates"
    }

    private static let script = #"""
    import json, sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    creates, made, held = [], {}, []
    def answer(frame):
        key = frame.get('idempotency_key')
        replayed = key in made
        made.setdefault(key, {'workspace_id': 'ws_%032d' % len(made), 'tab_id': 'tab_' + 'a' * 32, 'terminal_id': 'term_' + 'a' * 32})
        print(json.dumps({'protocol': 'cmux.protocol/2', 'type': 'response', 'id': frame.get('id'), 'ok': True,
            'result': {'value': made[key], 'revision': '1', 'replayed': replayed}}), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('cmd') == 'identify':
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': {'app': 'cmux-tui', 'protocol': 12,
                'generation': 'create-late-reply-test', 'capabilities': []}}), flush=True)
        elif frame.get('operation') == 'workspace.create':
            creates.append({'idempotency_key': frame.get('idempotency_key'), 'initial_content': frame['params'].get('initial_content')})
            if frame['params'].get('initial_content') != 'terminal':
                continue  # an empty create is never answered
            held.append(frame)
            if len(held) < 2:
                continue  # the first terminal's host is still starting on a loaded machine
            for earlier in held: answer(earlier)
            held.clear()
        elif frame.get('cmd') == 'test-creates':
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': {'creates': creates, 'workspaces': len(made)}}), flush=True)
        else:
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': {}}), flush=True)
    """#

    /// A connection whose request and terminal start deadlines (1 s) both run out before the held reply comes.
    private func connection() -> DaemonConnection {
        let bridge = DaemonBridge.fakePython(["-c", Self.script])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-create-late-reply-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), spawnTimeout: .seconds(1),
                                 terminalEnvironment: nil))
    }

    @Test func aCreateThatStartsATerminalIsAnsweredLateOnceUnderOneKey() async throws {
        let connection = connection()
        try await connection.start()
        let created: StateResourceClient.CreatedWorkspace
        let recorded: JSONValue
        do {
            created = try await connection.state.createWorkspace(name: "late", ephemeral: true, terminal: true, focus: false)
            recorded = try await connection.request(Recorded())
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
        #expect(created.terminalID?.rawValue == "term_" + String(repeating: "a", count: 32))
        let creates = try #require(recorded["creates"]?.arrayValue)
        #expect(creates.count == 2, "the late create was not sent again")
        let keys = creates.map { $0["idempotency_key"]?.stringValue }
        #expect(keys[0] != nil && keys.allSatisfy { $0 == keys[0] }, "a create sent again took a new idempotency key: \(keys)")
        #expect(recorded["workspaces"]?.doubleValue == 1, "sending again made a second workspace")
    }

    /// An empty create starts no terminal: it keeps the control-plane deadline and is never sent again.
    @Test func anEmptyCreateKeepsTheRequestDeadline() async throws {
        let connection = connection()
        try await connection.start()
        await #expect(throws: DaemonError.self) {
            try await connection.state.createWorkspace(name: "empty", ephemeral: false, terminal: false, focus: false)
        }
        let recorded = try? await connection.request(Recorded())
        await connection.close()
        #expect(recorded?["creates"]?.arrayValue?.count == 1)
    }
}

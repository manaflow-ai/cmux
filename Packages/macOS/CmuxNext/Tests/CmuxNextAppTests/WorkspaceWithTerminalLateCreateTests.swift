import CmuxNextDaemon
import CmuxNextWorkspaceRepair
import Foundation
import Testing
@testable import CmuxNextApp

/// P0 2026-10-30 ("I can no longer make new terminals"), lead decision: Cmd-N's workspace with its terminal is a new
/// terminal too. Its `create-workspace` asked again on a late reply only until a fixed 10 s budget; past it the create
/// threw and `WorkspaceCreation.withTerminal` closed the workspace the person already saw, while a busy cmux-tui still
/// made it. Now the create waits through late replies under its mutation id until the reply, a refusal or the
/// connection's end.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport. It makes one workspace per mutation id and
/// answers `create-workspace` only after its own delay (longer than the old budget); the first terminal is answered
/// at once. The workspace must be made once and never closed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct WorkspaceWithTerminalLateCreateTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-commands"
    }

    private static let script = #"""
    import json, sys, threading, time
    print('{"ok":true}', file=sys.stderr, flush=True)
    delay, start = float(sys.argv[1]), time.time()
    commands, workspaces, lock, started = [], {}, threading.Lock(), {}
    def reply(frame, data):
        with lock:
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def made(frame):
        key = frame.get('mutation_id') or 'unkeyed'
        with lock:
            replayed = key in workspaces
            if not replayed:
                workspaces[key] = 5 + len(workspaces)
        reply(frame, {'workspace': workspaces[key], 'key': frame.get('key'), 'workspace_revision': 1, 'replayed': replayed})
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command != 'identify':
            commands.append(command)
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'late-workspace-test', 'capabilities': []})
        elif command == 'create-workspace':
            # A busy daemon: every ask is answered once the slow start ends, the first one included.
            threading.Timer(max(0.0, start + delay - time.time()), made, args=(frame,)).start()
        elif command == 'create-terminal':
            # The first terminal's start ends once, 1.5 s after its first ask; an ask after that is replayed at once.
            started['terminal'] = started.get('terminal') or time.time()
            def answer(frame=frame):
                key = 'term-' + (frame.get('mutation_id') or 'unkeyed')
                with lock:
                    replayed = key in workspaces
                    workspaces.setdefault(key, 0)
                reply(frame, {'surface': 7, 'terminal_id': frame.get('terminal_id'), 'pane': 3, 'screen': 2,
                              'key': frame.get('key'), 'lifecycle': 'running', 'replayed': replayed})
            threading.Timer(max(0.0, started['terminal'] + 1.5 - time.time()), answer).start()
        elif command == 'test-commands':
            reply(frame, {'commands': commands, 'workspaces': len([k for k in workspaces if not str(k).startswith('term-')]),
                          'terminals': len([k for k in workspaces if str(k).startswith('term-')])})
        else:
            reply(frame, {})
    """#

    @Test func aWorkspaceWithATerminalThatIsCreatedLateIsWaitedForAndNeverClosed() async throws {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, "11"])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-late-workspace-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .milliseconds(500), spawnTimeout: .milliseconds(500),
                                 terminalEnvironment: nil))
        try await connection.start()
        let repair = EmptyWorkspaceRepair(store: DaemonStore(), create: { _ in nil }, close: { _ in }, cause: { _ in .tabClosed },
                                          canCreate: { true }, epoch: { 1 }, isLive: { true })
        let key = WorkspaceKey.generate()
        // The first terminal as every workspace-with-a-terminal caller makes it (Open Folder, fork, teams, incognito).
        let made = try await WorkspaceCreation.create(key, name: "late", on: connection, repair: repair) { created in
            _ = try await WorkspaceCreation.firstTerminal(in: created, cwd: "/tmp", on: connection)
            return created.rawValue
        }
        let recorded = try await connection.request(Recorded())
        await connection.close()

        #expect(made == key.rawValue)
        #expect(recorded["terminals"]?.doubleValue == 1, "the first terminal that starts late is waited for and made once")
        let commands = try #require(recorded["commands"]?.arrayValue).compactMap(\.stringValue)
        #expect(!commands.contains("close-workspace"), "the workspace the person saw was closed: \(commands)")
        #expect(recorded["workspaces"]?.doubleValue == 1, "asking again under one mutation id makes one workspace")
    }
}

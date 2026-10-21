@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextWorkspaceRepair
import Foundation
import Testing

/// Austin, 2026-10-20, on NIGHTLY with a busy Mac (load average over 600): Cmd-N's workspace
/// showed, then disappeared, focus left it and the window sometimes went blank. The daemon
/// answered `pin-workspace`, `create-workspace` and `new-conversation-tab` after the app's 2 s
/// control deadline; the app took the miss as a failed create, removed the workspace it showed
/// and closed the one the daemon had made (`closed list`: `workspace-102`, its New Tab page,
/// closed 1.2 s after the press).
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport that answers
/// `create-workspace` only after the connection's control deadline. The create must still
/// succeed, and no `close-workspace` may be sent.
@MainActor struct SlowDaemonWorkspaceCreateTests {
    private struct Recorded: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-commands"
    }

    private static let script = #"""
    import json, sys, time
    print('{"ok":true}', file=sys.stderr, flush=True)
    commands = []
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'slow-create-test', 'capabilities': []})
            continue
        commands.append(command)
        if command == 'create-workspace':
            time.sleep(1.5)  # past the 1 s control deadline below: the daemon is busy, not refusing
            params = frame.get('params') or frame
            reply(frame, {'workspace': 7, 'key': params.get('key'), 'workspace_revision': 1, 'replayed': False})
        elif command == 'test-commands':
            reply(frame, {'commands': commands})
        else:
            reply(frame, {})
    """#

    private func connection() -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        return DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-slow-create-test-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), terminalEnvironment: nil))
    }

    private func repair() -> EmptyWorkspaceRepair {
        EmptyWorkspaceRepair(store: DaemonStore(), create: { _ in nil }, close: { _ in }, cause: { _ in .tabClosed },
                             canCreate: { true }, epoch: { 1 }, isLive: { true })
    }

    @Test func aCreateThatAnswersAfterTheControlDeadlineKeepsItsWorkspace() async throws {
        let connection = connection()
        try await connection.start()
        let key = WorkspaceKey.generate()
        let made = await Result(catching: {
            try await WorkspaceCreation.createWithFirstTab(key, name: "workspace-102", on: connection, repair: repair()) { created in
                created.key.rawValue
            }
        })
        let recorded = try await connection.request(Recorded())
        await connection.close()

        #expect((try? made.get()) == key.rawValue, "the slow create still made the workspace: \(made)")
        let commands = recorded["commands"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(!commands.contains("close-workspace"), "a slow daemon never closes the new workspace: \(commands)")
    }

    @Test func aPersonsCreateHasALongerDeadlineThanAControlRequest() {
        let connection = connection()
        #expect(connection.createTimeout == DaemonConnection.defaultCreateTimeout)
        #expect(DaemonConnection.defaultCreateTimeout > DaemonConnection.defaultSpawnTimeout)
    }
}

private extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

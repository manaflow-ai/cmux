import Foundation
import Testing
@testable import CmuxNextDaemon

/// `action.run` answers with `created`: each object its run made, from what each creating request reports to the
/// run's scope (``DaemonCreatingRequest``). A new terminal workspace was two requests, `create-workspace` (it
/// reported the workspace) and `create-terminal` (the tab and the terminal). Since 650fd32b59b9 it is one
/// `create-terminal {create_workspace}` (`create-terminal-workspace-v1`), and that request reported only the tab and
/// the terminal: a script that made a workspace (`workspace.newAtBottom`) got no workspace id and could not go to it.
///
/// Socket boundary: a scripted daemon on the real JSON-lines transport with `create-terminal-workspace-v1`. It
/// answers `create-terminal` with the workspace key the request named, as cmux-tui does, refuses it (`refuse`), or
/// holds the first reply past the start deadline (`late`).
struct CreateTerminalWorkspaceCreatedTests {
    private static let script = #"""
    import json, sys
    mode = sys.argv[1]
    print('{"ok":true}', file=sys.stderr, flush=True)
    creates, held = 0, []
    def reply(frame, replayed=False):
        data = {'surface': 7, 'terminal_id': frame.get('terminal_id'), 'pane': 3, 'screen': 2, 'workspace': 5,
                'key': frame.get('key'), 'lifecycle': 'running', 'replayed': replayed}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': {
                'app': 'cmux-tui', 'protocol': 12, 'generation': 'created-test',
                'capabilities': ['create-terminal-workspace-v1']}}), flush=True)
        elif command == 'create-terminal':
            creates += 1
            if mode == 'refuse':
                print(json.dumps({'id': frame.get('id'), 'ok': False, 'error': 'no space left on device'}), flush=True)
            elif mode == 'late' and creates == 1:
                held.append(frame)  # the start ends after the app's deadline; the app asks again
            else:
                for earlier in held:
                    reply(earlier)
                reply(frame, replayed=bool(held))
                held.clear()
        else:
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': {}}), flush=True)
    """#

    private func connection(_ mode: String) -> DaemonConnection {
        DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-created-test-\(UUID().uuidString).sock",
                            bridge: DaemonBridge.fakePython(["-c", Self.script, mode])),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), spawnTimeout: .seconds(1),
                                 terminalEnvironment: nil))
    }

    /// The first terminal of `key` under a run's scope, as `WorkspaceCreation.create` sends it; `makesWorkspace`
    /// false: a terminal in a workspace that is there.
    private func firstTerminal(_ mode: String, in key: WorkspaceKey, makesWorkspace: Bool = true) async throws
        -> (created: [DaemonCreatedObject], result: Result<CreateTerminalResult, any Error>) {
        let connection = connection(mode)
        try await connection.start()
        let scope = DaemonCommandScope()
        let result: Result<CreateTerminalResult, any Error>
        do {
            result = .success(try await DaemonCommandScope.$current.withValue(scope) {
                if makesWorkspace {
                    let taken = await connection.makesWorkspace(with: NewTerminalWorkspace(key: key, name: "shell"))
                    #expect(taken, "the scripted daemon has create-terminal-workspace-v1")
                }
                return try await connection.createTerminalWaitingForStart(in: key, cwd: "/tmp")
            })
        } catch {
            result = .failure(error)
        }
        await connection.close()
        return (scope.created, result)
    }

    @Test func theWorkspaceThatTheFirstTerminalsRequestMadeIsCreatedFirst() async throws {
        let key = WorkspaceKey.generate()
        let run = try await firstTerminal("make", in: key)
        let made = try run.result.get()
        #expect(made.key == key, "the daemon's reply names the workspace it made")
        #expect(run.created == [
            DaemonCreatedObject(.workspace, key.rawValue), DaemonCreatedObject(.tab, "7"),
            DaemonCreatedObject(.terminal, made.terminalID.rawValue),
        ], "the workspace first, as when `create-workspace` was its own request: \(run.created)")
    }

    /// A request the daemon refused made nothing: `created` names no workspace that does not exist.
    @Test func aRefusedRequestCreatedNothing() async throws {
        let run = try await firstTerminal("refuse", in: WorkspaceKey.generate())
        #expect(throws: DaemonError.self) { try run.result.get() }
        #expect(run.created.isEmpty, "\(run.created)")
    }

    /// A start that ends after the deadline: the request is sent again under the same ids, and the one answer the
    /// app takes names the workspace once.
    @Test func aLateStartNamesTheWorkspaceOnce() async throws {
        let key = WorkspaceKey.generate()
        let run = try await firstTerminal("late", in: key)
        let made = try run.result.get()
        #expect(run.created == [
            DaemonCreatedObject(.workspace, key.rawValue), DaemonCreatedObject(.tab, "7"),
            DaemonCreatedObject(.terminal, made.terminalID.rawValue),
        ], "\(run.created)")
    }

    /// A terminal in a workspace that was there before made no workspace.
    @Test func aTerminalInAWorkspaceThatIsThereNamesNoWorkspace() async throws {
        let run = try await firstTerminal("make", in: WorkspaceKey.generate(), makesWorkspace: false)
        let made = try run.result.get()
        #expect(run.created == [DaemonCreatedObject(.tab, "7"), DaemonCreatedObject(.terminal, made.terminalID.rawValue)],
                "\(run.created)")
    }
}

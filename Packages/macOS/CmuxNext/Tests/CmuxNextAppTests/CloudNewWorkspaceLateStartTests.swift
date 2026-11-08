#if DEBUG
import AppKit
@testable import CmuxAuthRuntime
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextCloud
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A loaded Cloud machine may start its first terminal after the request deadline. The toggle's
/// real opener must wait for that terminal, rather than fail and make Retry open another workspace.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudNewWorkspaceLateStartTests {
    private struct Recorded: DaemonRequest {
        typealias Response = CmuxNextDaemon.JSONValue
        static let command = "test-cloud-creates"
    }

    private static let script = #"""
    import json, sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    commands, workspaces, creates, terminals, held = [], {}, [], {}, []
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def terminal(frame):
        mutation = frame.get('mutation_id') or 'unkeyed-%d' % len(creates)
        replayed = mutation in terminals
        terminals.setdefault(mutation, frame.get('terminal_id') or 'term-%d' % len(terminals))
        return {'surface': 7, 'terminal_id': terminals[mutation], 'pane': 3, 'screen': 2,
                'key': frame.get('key'), 'lifecycle': 'running', 'replayed': replayed}
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        commands.append(command)
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'cloud-late-test', 'capabilities': []})
        elif command == 'create-workspace':
            mutation = frame.get('mutation_id') or frame.get('key')
            workspaces.setdefault(mutation, frame.get('key'))
            reply(frame, {'workspace': 5, 'key': frame.get('key'), 'workspace_revision': 1, 'replayed': False})
        elif command == 'create-terminal':
            creates.append(frame)
            data = terminal(frame)
            if len(creates) == 1:
                held.append((frame, data))
                continue
            for earlier, answer in held:
                reply(earlier, answer)
            held.clear()
            reply(frame, data)
        elif command == 'test-cloud-creates':
            reply(frame, {'commands': commands, 'workspaces': len(workspaces),
                          'creates': creates, 'terminals': len(terminals)})
        elif command == 'list-workspaces':
            reply(frame, {'workspaces': []})
        elif command == 'close-workspace':
            reply(frame, {'workspace': 5, 'key': frame.get('key'), 'workspace_revision': 1, 'replayed': False})
        elif command == 'list-agents':
            reply(frame, {'agents': []})
        else:
            reply(frame, {})
    """#

    @Test func theToggleWaitsForItsLateFirstTerminalWithoutClosingOrDuplicatingItsWorkspace() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_AUTH_CAPTURE_FIXTURE": "1"]))
        services.cloud.debugBackendFixture = true
        services.cloud.auth.coordinator.currentUser = .init(id: "cloud-toggle-test", primaryEmail: nil, displayName: nil)
        services.cloud.auth.coordinator.isAuthenticated = true
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-late-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"cloud":{"newWorkspacesInCloud":true,"newWorkspaceFolder":"empty"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        let session = MachineIconTests.cloudMachine(services, id: "cloud-late-first-terminal")
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-cloud-late-\(UUID().uuidString).sock",
                            bridge: .fakePython(["-c", Self.script])),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), spawnTimeout: .seconds(1),
                                 terminalEnvironment: nil))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"cloud-late","workspace_key":"cloud-late"}"#.utf8))
        let route = CloudHandlers.startNewWorkspaceInCloud(ActionInvocation(origin: .user), cwd: nil,
                                                          window: WindowState(record: record), services)
        #expect(route == .started)
        let creation = try #require(services.cloud.creations.all.last)
        // Attach before yielding, then cancel the provider flow: no paid machine or network request.
        creation.attach(session)
        creation.task?.cancel()
        await creation.task?.value
        defer { services.cloud.creations.end(creation) }
        let open = try #require(creation.open)
        let identity = try await connection.start()
        session.daemon.start(first: { .success((connection, identity)) }, makeConnection: { connection })
        defer { session.daemon.shutdownConnection() }
        await session.daemon.firstConnection()
        var opened: String?
        var failure: (any Error)?
        do {
            opened = try await open(session)
        } catch {
            failure = error
        }
        let recorded: CmuxNextDaemon.JSONValue
        do {
            recorded = try await connection.request(Recorded())
        } catch {
            await connection.closeAndWait()
            throw error
        }
        await connection.closeAndWait()

        #expect(failure == nil, "the toggle abandoned its first terminal: \(String(describing: failure))")
        #expect(opened?.isEmpty == false)
        #expect(recorded["workspaces"]?.doubleValue == 1)
        #expect(recorded["terminals"]?.doubleValue == 1)
        let commands = try #require(recorded["commands"]?.arrayValue).compactMap(\.stringValue)
        #expect(!commands.contains("close-workspace"), "the toggle closed its workspace after the deadline")
        let creates = try #require(recorded["creates"]?.arrayValue)
        #expect(creates.count == 2, "the late start must be asked for again")
        let mutations = creates.compactMap { $0["mutation_id"]?.stringValue }
        let terminals = creates.compactMap { $0["terminal_id"]?.stringValue }
        #expect(mutations.count == creates.count && Set(mutations).count == 1)
        #expect(terminals.count == creates.count && Set(terminals).count == 1)
    }
}

#endif

import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextFocusUI
import Foundation
import Testing

/// New Terminal Tab and Split against a daemon that answers before the terminal's host is up
/// (`terminal-async-start-v1`, p05-ipc-131): the command's work ends at the reply, before
/// `terminal-started` (so the window's held keys, focus, sizing and a capturing caller resolve
/// there), the reply settles the stand-in, and a `terminal-start-failed` is only the follow-up's:
/// the daemon's rollback removes the tab, leaving the pane exactly as it was, and the refusal HUD
/// says why.
///
/// Socket boundary: the app's services on a scripted daemon (python3 through a ``DaemonBridge``)
/// that holds each start until the test releases it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct NewTerminalTabCommandTests {
    private struct Release: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "test-release-start"
    }

    private struct State: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "test-state"
    }

    private static let pane = PaneID(rawValue: 3)

    /// argv[1]: what the release emits, `started` or `failed`.
    private static let script = #"""
    import json, sys
    outcome = sys.argv[1]
    print('{"ok":true}', file=sys.stderr, flush=True)
    caps = ['terminal-placement-env-v1', 'split-client-keys-v1', 'terminal-async-start-v1']
    tabs = [{'surface': 4, 'kind': 'pty', 'terminal_id': 'first'}]
    state = {'revision': 1, 'started': False, 'pending': []}
    def reply(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def event(name, **fields):
        fields['event'] = name
        print(json.dumps(fields), flush=True)
    def changed():
        state['revision'] += 1
        event('tree-changed')
    def tree():
        pane = {'id': 3, 'tabs': list(tabs), 'active_tab': len(tabs) - 1}
        screen = {'id': 2, 'active': True, 'active_pane': 3, 'layout': {'type': 'leaf', 'pane': 3}, 'panes': [pane]}
        workspace = {'id': 1, 'key': '00000000-0000-4000-8000-000000000001', 'name': '1', 'active': True, 'screens': [screen]}
        return {'workspace_revision': state['revision'], 'workspaces': [workspace]}
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'async-start-app-test', 'capabilities': caps})
        elif command == 'list-workspaces':
            reply(frame, tree())
        elif command == 'new-tab':
            terminal = frame.get('terminal_id')
            tabs.append({'surface': 7, 'kind': 'pty', 'terminal_id': terminal})
            state['pending'].append(terminal)
            changed()  # admitted: its events go before the reply
            reply(frame, {'surface': 7, 'terminal_id': terminal, 'starting': frame.get('async_start') is True})
        elif command == 'split':
            terminal = frame.get('terminal_id')
            state['pending'].append(terminal)
            reply(frame, {'surface': 9, 'terminal_id': terminal, 'starting': frame.get('async_start') is True})
        elif command == 'test-release-start':
            for terminal in state['pending']:
                if outcome == 'started':
                    state['started'] = True
                    event('terminal-started', terminal_id=terminal)
                else:
                    event('terminal-start-failed', terminal_id=terminal, error='exec failed')
                    tabs[:] = [tab for tab in tabs if tab['terminal_id'] != terminal]
                    changed()  # the rollback of the admitted tab
            state['pending'] = []
            reply(frame, {})
        elif command == 'test-state':
            reply(frame, {'started': state['started']})
        else:
            reply(frame, {})
    """#

    private static func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "timed out: \(what)")
    }

    /// The app's services connected to the scripted daemon, its first snapshot mirrored.
    private static func withDaemon(_ outcome: String, _ body: (DaemonService, DaemonConnection, AppServices) async throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, outcome])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-async-start-app-\(UUID().uuidString.prefix(8)).sock", bridge: bridge)
        services.daemon.start {
            DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        }
        defer { services.daemon.shutdownConnection() }
        let daemon = services.daemon
        try await until("the first snapshot") { daemon.store.pane(pane)?.tabs.map(\.surface) == [SurfaceID(rawValue: 4)] }
        try await until("the capability") { daemon.supports(DaemonCapability.terminalAsyncStart.rawValue) }
        let connection = try #require(daemon.connection)
        try await body(daemon, connection, services)
    }

    private static func surfaces(_ daemon: DaemonService) -> [SurfaceID] {
        daemon.store.pane(pane)?.tabs.map(\.surface) ?? []
    }

    /// Whether the pane holds a stand-in still.
    private static func showsStandIn(_ daemon: DaemonService) -> Bool {
        surfaces(daemon).contains(where: ProvisionalTab.isProvisional(surface:))
    }

    @Test func theWorkEndsAtTheReplyBeforeTheTerminalStarted() async throws {
        try await Self.withDaemon("started") { daemon, connection, _ in
            let command = NewTerminalTabCommand(pane: Self.pane, options: SpawnOptions())
            #expect(command.isOptimistic(on: daemon))
            let pending = command.intendNow(on: daemon)
            #expect(Self.surfaces(daemon) == [SurfaceID(rawValue: 4), pending.surface], "the stand-in shows in the key's turn")

            // Nothing releases the start yet: the work (and the key hold behind it) must end anyway.
            let reply = try await pending.send()
            let state = try await connection.request(State())
            #expect(state["started"]?.boolValue == false, "the work ended before terminal-started")
            #expect(reply.created.surface == SurfaceID(rawValue: 7))
            #expect(reply.isStarting)
            try await Self.until("the daemon's tab in the stand-in's place") {
                Self.surfaces(daemon) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 7)] && daemon.store.pendingIntents.isEmpty
            }

            _ = try await connection.request(Release())
            #expect(await reply.outcome() == .started)
            #expect(Self.surfaces(daemon) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 7)])
        }
    }

    @Test func aSplitsWorkEndsAtTheReplyBeforeTheTerminalStarted() async throws {
        try await Self.withDaemon("failed") { daemon, connection, _ in
            let command = PaneSplitCommand(pane: Self.pane, direction: .right, options: SpawnOptions(), swapTowards: nil)
            #expect(command.isOptimistic(on: daemon))
            let reply = try await command.intendNow(on: daemon, provisional: ProvisionalPane())()
            let state = try await connection.request(State())
            #expect(state["started"]?.boolValue == false, "the split's work ended before its terminal's start")
            #expect(reply.created.surface == SurfaceID(rawValue: 9))
            #expect(reply.isStarting)

            _ = try await connection.request(Release())
            #expect(await reply.outcome().failure?.reason == "exec failed", "the start's failure is the follow-up's, not the split's")
        }
    }

    @Test func aFailedStartRemovesTheStandInExactlyAndSaysWhy() async throws {
        try await Self.withDaemon("failed") { daemon, connection, services in
            AppActionContext(services: services).observeRefusals()
            let command = NewTerminalTabCommand(pane: Self.pane, options: SpawnOptions())
            let pending = command.intendNow(on: daemon)
            let reply = try await pending.send()
            try await Self.until("the reply settled the stand-in") {
                Self.surfaces(daemon) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 7)] && daemon.store.pendingIntents.isEmpty
            }
            reply.followStart(after: "newSurface", in: services.registry)

            _ = try await connection.request(Release())
            try await Self.until("the rollback") { Self.surfaces(daemon) == [SurfaceID(rawValue: 4)] }
            #expect(!Self.showsStandIn(daemon))
            #expect(daemon.store.pendingIntents.isEmpty)
            #expect(daemon.store.mirrorViolations.isEmpty)
            let reason = RefusalStrings.terminalDidNotStart("exec failed")
            try await Self.until("the refusal HUD names the failed start") {
                services.refusalHUD.history.contains { $0.contains(reason) }
            }
        }
    }
}

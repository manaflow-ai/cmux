import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSidebar
import Foundation
import Testing

/// Restore fuzz finding h3 (chaos diskfull, STATUS 3213): on a full daemon state disk the person's
/// New Workspace (`newTab`, origin user) is refused by the daemon ("pin-workspace failed: database or
/// disk is full"). The app correctly keeps no row, but the person sees nothing: no refusal, no toast,
/// no dialog. The person's run shows one refusal, "<action> did not apply: the disk is full", in
/// their language; a scripted run gets the typed daemon error back and shows nothing.
///
/// The app runs on a stand-in daemon behind a bridge (never a real daemon): it lists one workspace
/// and refuses every create and pin the way cmux-tui does on a full disk (`operation.failed`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct NewWorkspaceDiskFullRefusalTests {
    private static let daemonScript = #"""
    import json, sys
    log = open(sys.argv[1], 'a')
    FULL = {'code': 'operation.failed', 'message': 'database or disk is full', 'retryable': False,
            'details': {'operation': 'resource.runtime', 'reason': 'database or disk is full'}}
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        cmd, data = request.get('cmd'), {}
        log.write(f"{cmd}\n"); log.flush()
        if cmd == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'session': 's-local', 'registry_id': 's-local',
                    'generation': 'diskfull', 'capabilities': []}
        elif cmd == 'list-workspaces':
            data = {'registry_id': 's-local', 'workspaces': [{'id': 1, 'key': 'k1', 'name': 'First', 'screens': []}]}
        elif cmd in ('create-workspace', 'pin-workspace'):
            print(json.dumps({'id': request.get('id'), 'ok': False, 'error': FULL}), flush=True)
            continue
        print(json.dumps({'id': request.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    /// The commands the stand-in received, in order (a failure message names them).
    private static func commands(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The app connected to the stand-in, with one window on its workspace; `body` gets the stand-in's command log.
    private static func withApp(_ body: (AppServices, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        // The app's actions, as the app binds them at launch: without them `perform` runs nothing.
        AppActions.bind(services)
        let savedDocument = SidebarDocStore.current
        SidebarDocStore.current = nil
        defer { SidebarDocStore.current = savedDocument }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("cn-diskfull-create-\(UUID().uuidString.prefix(8)).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let bridge = DaemonBridge.fakePython(["-c", Self.daemonScript, log.path])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-diskfull-create-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        let identity = try await connection.start()
        services.daemon.start(first: { .success((connection, identity)) }, makeConnection: { connection })
        defer { services.daemon.shutdownConnection() }
        try await PlacementStaleRowsGalleryTests.waitForInitialSnapshot(services)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["k1"]))
        defer { controller.teardown(); controller.window?.close() }
        try await body(services, log)
    }

    /// Test-harness poll for work on other tasks; the limit is only a failure deadline.
    private static func eventually(_ done: () -> Bool) async -> Bool {
        for _ in 0..<1000 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    /// Lets a second, wrong refusal show before the count is read (test harness).
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(500))
    }

    @Test func aPersonsNewWorkspaceRefusedOnAFullDiskShowsOneRefusalSayingTheDiskIsFull() async throws {
        try await Self.withApp { services, log in
            let hud = services.refusalHUD
            let before = hud.shownCount
            let ran = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
            try #require(ran, "New Workspace did not run for the person")
            let refused = await Self.eventually { Self.commands(log).contains { $0 == "create-workspace" || $0 == "pin-workspace" } }
            try #require(refused, "the create never reached the daemon: \(Self.commands(log))")
            let shown = await Self.eventually { hud.shownCount > before }
            #expect(shown, "the daemon refused the person's New Workspace on a full disk and the person saw nothing: \(Self.commands(log))")
            await Self.settle()
            #expect(hud.shownCount == before + 1, "one refused create showed \(hud.shownCount - before) refusals: \(hud.history.suffix(3))")
            let message = hud.history.last ?? ""
            // The localized reason itself (REVIEW.md: never assert English text).
            #expect(message.contains(RefusalStrings.diskFull), "the refusal does not say the disk is full: \(message)")
            #expect(message != RefusalStrings.diskFull, "the refusal does not name the change that did not apply: \(message)")
            #expect(!message.contains("operation.failed"), "the refusal shows the daemon's raw error: \(message)")
        }
    }

    @Test func aScriptedNewWorkspaceRefusedOnAFullDiskGetsTheTypedErrorAndShowsNothing() async throws {
        try await Self.withApp { services, log in
            let hud = services.refusalHUD
            let before = hud.shownCount
            var ran = false
            let work = services.registry.capturingWork {
                ran = services.registry.perform("newTab", invocation: ActionInvocation(origin: .script))
            }
            try #require(ran, "New Workspace did not run for the script")
            var failures: [ActionWorkFailure] = []
            for task in work {
                if let failure = await task.value { failures.append(failure) }
            }
            #expect(failures.count == 1, "the scripted create's failures: \(failures) (\(work.count) tasks; daemon saw \(Self.commands(log)))")
            let failure = try #require(failures.first)
            #expect(failure.refusal == nil, "a daemon refusal became a handler refusal: \(failure)")
            #expect(failure.message.contains("database or disk is full"), "the caller lost the daemon's error: \(failure.message)")
            await Self.settle()
            #expect(hud.shownCount == before, "a scripted create showed the person a refusal: \(hud.history.suffix(3))")
        }
    }
}

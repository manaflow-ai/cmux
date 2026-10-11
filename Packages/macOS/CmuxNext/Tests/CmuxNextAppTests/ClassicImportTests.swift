import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextOnboarding
import Foundation
import Testing

/// `workspace.importClassic` (cx-rwlb), end to end: the real daemon, the app's
/// actions, and a real classic 0.64.19 session file
/// (tests/fixtures/classic-to-next, shared with classic-to-next.py's test).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicImportTests {
    private static let fixture: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("tests/fixtures/classic-to-next/session-com.cmuxterm.app.json")
    }()

    /// The pane tree as text: tab names in a pane, `right(…|…)` / `down(…|…)` for a split.
    private static func shape(_ node: LayoutNode, _ panes: [PaneSnapshot]) -> String {
        switch node {
        case .leaf(let id):
            return (panes.first { $0.id == id }?.tabs ?? []).map { $0.name ?? $0.title }.joined(separator: ",")
        case .split(_, let direction, _, let a, let b):
            return "\(direction.rawValue)(\(shape(a, panes))|\(shape(b, panes)))"
        default:
            return "?"
        }
    }

    /// The person runs Import Workspaces from Classic cmux: classic's split
    /// workspace opens with the same panes, tabs, tab names and directions.
    @Test func importKeepsTheClassicSplitWorkspace() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-classic-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        // The fixture's folders, moved under this test's scratch directory.
        let proj = root.appendingPathComponent("proj")
        for folder in ["api/logs", "web", "db"] {
            try FileManager.default.createDirectory(at: proj.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let session = try String(contentsOf: Self.fixture, encoding: .utf8)
            .replacingOccurrences(of: "/Users/cmux/p4rt-classic/proj", with: proj.path)
            .replacingOccurrences(of: "/Users/cmux", with: root.path)
        let file = root.appendingPathComponent("session-com.cmuxterm.app.json")
        try session.write(to: file, atomically: true, encoding: .utf8)

        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-classic-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.onboarding.classicSessions = ClassicSessionImporter(fileURL: file)
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer {
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
        }
        let deadline = ContinuousClock.now + .seconds(90)
        // The launch is ready once restore has made its first terminal.
        while !services.daemon.store.workspaces.contains(where: { $0.screens.contains { !$0.panes.isEmpty } }),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let connection = try #require(services.daemon.connection)

        var ran = false
        let work = services.registry.capturingWork { ran = services.registry.perform("workspace.importClassic") }
        #expect(ran, "workspace.importClassic is not an action")
        for task in work { #expect(await task.value == nil) }

        let tree = try await connection.listWorkspaces()
        let screen = try #require(tree.workspaces.first { workspace in
            workspace.screens.contains { $0.panes.contains { $0.tabs.contains { ($0.name ?? $0.title) == "web" } } }
        }?.screens.first, "no imported workspace holds classic's web tab")
        let trees = [screen.layout] + screen.columns.flatMap { [$0.layout] + $0.rows.map(\.layout) }
        let shapes = trees.map { Self.shape($0, screen.panes) }
        // Left: api and logs as tabs of one pane; right: web over db.
        #expect(shapes.contains("right(api,logs|down(web|db))"), "\(shapes)")
        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
    }
}

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
        let shapes = try await importedShapes { $0 }
        // Left: api and logs as tabs of one pane; right: web over db.
        #expect(shapes.contains("right(api,logs|down(web|db))"), "\(shapes)")
    }

    /// A browser panel does not come over (cmux-next has no classic browser
    /// state to open), and is not a stray terminal either: a pane that held
    /// only a browser closes up.
    @Test func aBrowserOnlyPaneClosesUp() async throws {
        let db = "\"title\":\"db\",\"ttyName\":\"ttys023\",\"type\":\"terminal\""
        let shapes = try await importedShapes { session in
            #expect(session.contains(db), "the fixture's db panel changed")
            return session.replacingOccurrences(of: db, with: "\"title\":\"db\",\"type\":\"browser\"")
        }
        #expect(shapes.contains("right(api,logs|web)"), "\(shapes)")
    }

    /// An SSH or Cloud VM workspace stays in classic: its terminals ran on
    /// another machine, and a local shell in its folder is the wrong place.
    @Test func aRemoteWorkspaceStaysInClassic() async throws {
        let title = "\"customTitle\":\"split api\""
        let shapes = try await importedShapes { session in
            #expect(session.contains(title), "the fixture's split workspace changed")
            return session.replacingOccurrences(of: title, with: title + ",\"remote\":{\"destination\":\"dev.example.test\"}")
        }
        #expect(shapes.isEmpty, "\(shapes)")
    }

    /// Runs the action on the fixture (after `edit`) and returns the pane
    /// trees of the workspace holding classic's web tab (none when no
    /// workspace holds it).
    private func importedShapes(_ edit: (String) -> String) async throws -> [String] {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-classic-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        // The fixture's folders, moved under this test's scratch directory.
        let proj = root.appendingPathComponent("proj")
        for folder in ["api/logs", "web", "db"] {
            try FileManager.default.createDirectory(at: proj.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // Classic writes `\/` in paths; plain `/` reads the same.
        let session = try edit(String(contentsOf: Self.fixture, encoding: .utf8).replacingOccurrences(of: "\\/", with: "/"))
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
        // The daemon ends with its terminals on every path, a failed expectation included.
        let shapes: Result<[String], any Error>
        do { shapes = .success(try await Self.importAndRead(services)) } catch { shapes = .failure(error) }
        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        return try shapes.get()
    }

    /// Waits for the launch, runs the action and returns the pane trees of
    /// the workspace holding classic's web tab, if one does.
    private static func importAndRead(_ services: AppServices) async throws -> [String] {
        let deadline = ContinuousClock.now + .seconds(90)
        // The launch is ready once restore has made its first terminal.
        func ready() -> Bool { services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } } }
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try #require(ready(), "the launch made no terminal")
        let connection = try #require(services.daemon.connection)

        var ran = false
        let work = services.registry.capturingWork { ran = services.registry.perform("workspace.importClassic") }
        #expect(ran, "workspace.importClassic is not an action")
        for task in work { #expect(await task.value == nil) }

        let tree = try await connection.listWorkspaces()
        guard let screen = tree.workspaces.first(where: { workspace in
            workspace.screens.contains { $0.panes.contains { $0.tabs.contains { ($0.name ?? $0.title) == "web" } } }
        })?.screens.first else { return [] }
        let trees = [screen.layout] + screen.columns.flatMap { [$0.layout] + $0.rows.map(\.layout) }
        return trees.map { shape($0, screen.panes) }
    }
}

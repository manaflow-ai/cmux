import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The pinned hosted cmux-tui (`scripts/cmux-next/pin-cmux-tui.sh fetch`).
nonisolated enum PinnedDaemonBinary {
    static let url: URL? = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        guard let pin = try? String(contentsOf: root.appendingPathComponent("scripts/cmux-next/cmux-tui.pin"), encoding: .utf8),
              let commit = pin.split(separator: "\n").first(where: { $0.hasPrefix("commit=") })?.dropFirst("commit=".count) else {
            return nil
        }
        let binary = root.appendingPathComponent("cmux-tui/target/hosted/\(commit)/cmux-tui")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }()
}

/// A fresh session, end to end: the real daemon, the app's launch window,
/// restore, and the empty-workspace guard.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: PinnedDaemonBinary.url != nil, "needs the pinned cmux-tui"))
struct FirstLaunchTests {
    private static func tabs(_ store: DaemonStore) -> Int {
        store.workspaces.reduce(0) { $0 + $1.screens.reduce(0) { $0 + $1.panes.reduce(0) { $0 + $1.tabs.count } } }
    }

    /// Regression (dogfood nxdog3): a fresh session's first pane started with
    /// two terminal tabs. restore() created the workspace and its terminal,
    /// and the moment create-terminal replied (before its pane delta reached
    /// the mirror) the new window's content saw an empty workspace and the
    /// empty-workspace guard sent a second create-terminal.
    @Test func freshSessionStartsWithExactlyOneTerminal() async throws {
        let binary = try #require(PinnedDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-first-\(UUID().uuidString.prefix(8))")
        let session = "cn-first-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let store = services.daemon.store
        defer { try? FileManager.default.removeItem(at: root) }

        let deadline = ContinuousClock.now + .seconds(20)
        while Self.tabs(store) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Give a duplicate create-terminal time to land; test-only wait.
        try await Task.sleep(for: .seconds(2))
        let workspaces = store.workspaces.count
        let tabs = Self.tabs(store)

        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }

        #expect(workspaces == 1)
        #expect(tabs == 1)
    }
}

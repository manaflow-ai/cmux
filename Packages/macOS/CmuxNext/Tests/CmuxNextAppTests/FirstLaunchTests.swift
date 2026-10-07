import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The hosted build of this checkout's cmux-tui tree
/// (`scripts/cmux-next/pin-cmux-tui.sh fetch`; `path` names it).
nonisolated enum SameTreeDaemonBinary {
    static let url: URL? = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/cmux-next/pin-cmux-tui.sh").path, "path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }()
}

/// A fresh session, end to end: the real daemon, the app's launch window,
/// restore, and the empty-workspace guard.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct FirstLaunchTests {
    /// Returns once `store` has a tab or `limit` passes, whichever is first.
    /// A poll, not a task group over `Observations`: the Swift 6.2 region
    /// isolation checker rejects that pattern in this suite.
    private static func firstTab(in store: DaemonStore, within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while tabs(store) == 0, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func tabs(_ store: DaemonStore) -> Int {
        store.workspaces.reduce(0) { $0 + $1.screens.reduce(0) { $0 + $1.panes.reduce(0) { $0 + $1.tabs.count } } }
    }

    /// Regression (dogfood nxdog3): a fresh session's first pane started with
    /// two terminal tabs. restore() created the workspace and its terminal,
    /// and the moment create-terminal replied (before its pane delta reached
    /// the mirror) the new window's content saw an empty workspace and the
    /// empty-workspace guard sent a second create-terminal.
    @Test func freshSessionStartsWithExactlyOneTerminal() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
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

        // No wall-clock deadline tight enough to trip on a stalled test process
        // (CI runs saw every test stall for 24-41 s); a launch that never makes a
        // tab still ends here, so the daemon below is always shut down.
        await Self.firstTab(in: store, within: .seconds(90))
        // Give a duplicate create-terminal time to land; test-only wait.
        try? await Task.sleep(for: .seconds(2))
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

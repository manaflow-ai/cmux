import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// #17587 review (c045514126a, 17c54b8c616): the launch drops the panes' last frames no pane took once
/// each restored window with a workspace to show showed its first content. Only workspace content
/// counted (`contentDidAppear`), so a window restored on a top page (or the classic Home dock, or a
/// Cloud creation) never counted and kept every decoded frame for the session (about 5 MB per Retina
/// pane); a pane built hours later still drew a last-quit frame. The boundary: the app's restore on a
/// same-tree daemon whose saved window shows the History page over its workspace.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct LaunchFrameReleaseTopPageTests {
    @Test func aWindowRestoredOnATopPageDoesNotHoldTheLaunchFrames() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-lfr-page-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-lfr-page-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let result: Result<Void, any Error>
        do {
            // What the last quit saved: one window, left on the History page over its workspace.
            try await Self.until({ services.daemon.connection != nil && services.daemon.windowState != nil && services.daemon.store.isLoaded })
            let connection = try #require(services.daemon.connection)
            let key = WorkspaceKey.generate()
            _ = try await connection.createWorkspace(name: "restored", key: key)
            try await Self.until({ services.daemon.store.workspaces.contains { $0.id == key.rawValue } })
            let windowID = "restored-on-page", page = TopPageRoute.page(.history).rawValue
            let windowState = try #require(services.daemon.windowState)
            _ = try await windowState.update { document in
                document.windows = [WindowRecord(id: windowID, workspaceKey: key, workspaceKeys: [key], page: page)]
            }

            services.windows.restoreWhenLoaded()
            try await Self.until({ !services.windows.registry.isLaunching })
            let controller = try #require(services.windows.controller(for: windowID), "the launch window adopts the saved window")
            try await Self.until({ controller.shownTopPage == .page(.history) })
            #expect(controller.content == nil, "the window shows its page, not its workspace")
            // The page showed in a turn that also tells the release (one path for every content kind).
            #expect(services.windows.launchFrameRelease?.isReleased == true,
                    "a window restored on a top page kept every decoded launch frame for the session")
            result = .success(())
        } catch { result = .failure(error) }
        // Stop the app's connection first: on the daemon's EOF it would start a fresh daemon that
        // outlives the test. The shutdown uses its own socket.
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        try result.get()
    }

    /// Polls `condition` (the store follows the daemon's events) up to a deadline; a timeout is
    /// reported at the caller's line.
    private static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(60),
                              sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "timed out", sourceLocation: sourceLocation)
    }
}

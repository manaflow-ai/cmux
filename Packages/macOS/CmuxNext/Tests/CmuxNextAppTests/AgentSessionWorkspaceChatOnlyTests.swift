import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Darwin
import Foundation
import Testing

private actor AgentSessionWorkspaceTestLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// `agent.openSessionWorkspace` (`cmux agent open`, the Chief's subagents, Start Agent's Return) on the
/// real daemon: the new workspace's only tab is the session's chat. It used to get a terminal running
/// `acpmux attach` first, a bare "~" shell whenever that start missed its deadline (Leo, 2026-10-28:
/// "you guys made all these empty terminal things ... I'd rather just see the other thing instead of
/// that, you know, tilde.").
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentSessionWorkspaceChatOnlyTests {
    @Test func openSessionWorkspaceMakesNoTerminal() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-chat-only-\(UUID().uuidString.prefix(8))")
        let session = "cn-chat-only-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        let store = services.daemon.store
        defer { try? FileManager.default.removeItem(at: root) }
        let tabs = services.agentTabs
        tabs.localHost = AgentSessionRef.host(installID: "chat-only-test")
        tabs.holdsTabs = { _ in true }
        let connectBy = ContinuousClock.now + .seconds(60)
        while services.daemon.connection == nil || services.daemon.identity == nil, ContinuousClock.now < connectBy {
            try await Task.sleep(for: .milliseconds(100))
        }

        let key = WorkspaceKey.generate()
        var failure: String?
        var workspace: WorkspaceModel?
        if tabs.canHostChat, services.daemon.connection != nil {
            let work = try AgentSessionWorkspace.open(session: "s-chat-only", name: "lane", key: key, cwd: "/tmp", services: services)
            failure = await work.value?.message
            // The store mirrors the tab after the reply; test-only wait.
            let mirrorBy = ContinuousClock.now + .seconds(10)
            while workspace?.screens.first?.panes.first?.tabs.isEmpty != false, ContinuousClock.now < mirrorBy {
                workspace = store.workspaces.first { $0.key == key }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let made = workspace.map { $0.screens.flatMap(\.panes).flatMap(\.tabs) } ?? []

        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }

        try #require(tabs.canHostChat, "this build has no agent page")
        #expect(failure == nil, "refused: \(failure ?? "")")
        #expect(made.filter { $0.kind == .pty }.count == 0, "the workspace got a terminal")
        #expect(made.count == 1)
        #expect(made.first?.kind == .conversation)
    }

    /// A busy daemon can commit the workspace's conversation tab after the app's short request
    /// deadline. Agent-open has no provisional row to take back, so it must keep retrying the
    /// keyed first-tab request until the commit is acknowledged instead of leaving an
    /// about:blank-only workspace behind.
    @Test func openSessionWorkspaceWaitsForALateConversationTab() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-chat-only-late-\(UUID().uuidString.prefix(8))")
        let session = "cn-chat-only-late-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        let store = services.daemon.store
        var daemonPID: Int32?
        defer {
            // Detach the reconnecting connection before signaling the owned daemon, even when an
            // assertion exits the test while the process is stopped.
            services.daemon.shutdownConnection()
            if let daemonPID {
                _ = kill(daemonPID, SIGCONT)
                _ = kill(daemonPID, SIGTERM)
            }
            try? FileManager.default.removeItem(at: root)
        }
        let tabs = services.agentTabs
        tabs.localHost = AgentSessionRef.host(installID: "chat-only-late-test")
        tabs.holdsTabs = { _ in true }
        let connectBy = ContinuousClock.now + .seconds(60)
        while services.daemon.connection == nil || services.daemon.identity == nil, ContinuousClock.now < connectBy {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(tabs.canHostChat, "this build has no agent page")
        let pid = try #require(services.daemon.identity?.pid)
        daemonPID = pid
        let key = WorkspaceKey.generate()
        let workspaceCreated = AgentSessionWorkspaceTestLatch()
        let releaseFirstTab = AgentSessionWorkspaceTestLatch()
        let work = try AgentSessionWorkspace.open(session: "s-chat-only-late", name: "late lane", key: key, cwd: "/tmp",
                                                  services: services, beforeFirstTab: {
                                                      // Hold the keyed first-tab request until the test has stopped the daemon.
                                                      // The daemon has committed the workspace, but no tab request has been sent yet.
                                                      await workspaceCreated.open()
                                                      await releaseFirstTab.wait()
                                                  })
        defer { Task { await releaseFirstTab.open() } }

        // Stop after the workspace is visible but before its first conversation tab request starts.
        await workspaceCreated.wait()
        try await PasswordManagerRouteTests.until({
            store.workspaces.contains { workspace in
                workspace.key == key && workspace.screens.flatMap(\.panes).flatMap(\.tabs).isEmpty
            }
        }, within: .seconds(10))
        #expect(kill(pid, SIGSTOP) == 0)
        // Let the keyed tab request go out while the daemon is stopped. Its first short
        // deadline must expire before the daemon resumes, forcing the production retry path.
        await releaseFirstTab.open()
        // The old ten-second keyed-tab budget must expire while the daemon is stopped.
        try await Task.sleep(for: .seconds(12))
        #expect(kill(pid, SIGCONT) == 0)
        let failure = await work.value?.message

        try await PasswordManagerRouteTests.until({
            store.workspaces.first(where: { $0.key == key })?.screens.flatMap(\.panes).flatMap(\.tabs).count == 1
        }, within: .seconds(20))
        let made = store.workspaces.first(where: { $0.key == key })?.screens.flatMap(\.panes).flatMap(\.tabs) ?? []
        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }

        #expect(failure == nil, "refused: \(failure ?? "")")
        #expect(made.count == 1, "the late first tab was not attached: \(made)")
        #expect(made.first?.kind == .conversation)
    }
}

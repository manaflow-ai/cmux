import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

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
}

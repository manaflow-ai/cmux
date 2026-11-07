import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// `agent.openSessionWorkspace` (`cmux agent open`) for a chat this Mac cannot hold makes no workspace.
/// It used to create the workspace, have its chat tab refused, then close it: a row that showed in the
/// sidebar and went again (Leo, 2026-11-05: "randomly there's these workspaces that appear and disappear").
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentSessionWorkspaceRefusalTests {
    @Test func aChatOnAnotherHostMakesNoWorkspace() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-refused-open-\(UUID().uuidString.prefix(8))")
        let session = "cn-refused-open-\(UUID().uuidString.prefix(8).lowercased())"
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
        tabs.localHost = AgentSessionRef.host(installID: "refused-open-test")
        tabs.holdsTabs = { _ in true }
        let connectBy = ContinuousClock.now + .seconds(60)
        while services.daemon.connection == nil || services.daemon.identity == nil, ContinuousClock.now < connectBy {
            try await Task.sleep(for: .milliseconds(100))
        }

        let key = WorkspaceKey.generate()
        var refusal: String?
        var listed = false
        var keyFree = false
        if tabs.canHostChat, let connection = services.daemon.connection {
            do {
                // A session on a lane VM: this Mac's daemon refuses its chat tab ("runs on host").
                let work = try AgentSessionWorkspace.open(session: "s-elsewhere", name: "lane", key: key, cwd: "/tmp",
                                                          host: "gcp-agent-lane-9", services: services)
                // Watch the store while the open runs: a made-then-closed workspace lists for a moment.
                let watch = Task { @MainActor in
                    while !Task.isCancelled {
                        if store.workspaces.contains(where: { $0.key == key }) { listed = true }
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                }
                refusal = await work.value?.message
                try await Task.sleep(for: .milliseconds(200))
                watch.cancel()
            } catch {
                refusal = String(describing: error)
            }
            // The daemon tombstones a closed workspace's key: the key is free only if no workspace was ever made with it.
            keyFree = (try? await connection.createWorkspaceWaitingForReply(name: "probe", key: key)) != nil
        }

        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }

        try #require(tabs.canHostChat, "this build has no agent page")
        #expect(refusal != nil, "a chat of another host opened")
        #expect(!listed, "the refused chat's workspace listed in the store (a sidebar row that came and went)")
        #expect(keyFree, "the daemon made, then closed, a workspace for a refused chat")
    }
}

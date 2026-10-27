import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// An agent chat tab's session as the control snapshot shows it (`snapshot.get`, the CLI's tree,
/// the agent caller lookup), against a real cmux-tui daemon. The tab's session changes after the
/// tab exists when a person picks another chat in it (the page's bind, `bind-conversation-tab-session`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentTabSessionTopologyTests {
    /// A chat picked in an open chat tab shows in the control snapshot right away, not only after
    /// a relaunch rebuilt it. The tab's title and everything else stay the same, so only the
    /// session tells the snapshot the tab changed (cx-sy3w1).
    @Test func aChatPickedInAnOpenTabShowsInTheControlSnapshot() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-tabbind-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let launcher = DaemonLauncher(work: BackgroundWork(label: "test.daemon-launcher"), configuration: .init(binary: binary, session: "cn-tabbind-\(UUID().uuidString.prefix(6).lowercased())",
                                                           stateDirectory: root.appendingPathComponent("state")), environment: environment)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        // Always end the daemon, so a failed expectation never leaves one running.
        let result: Result<Void, any Error>
        do {
            try await Self.pickAChat(services)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }

    private static func pickAChat(_ services: AppServices) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        func until(_ done: () -> Bool) async {
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
        await until { services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } } }
        let connection = try #require(services.daemon.connection, "the daemon did not come up")
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-tabbind-test"), hostName: "This Mac", session: "chat-first", harness: "claude")
        let created = try await connection.request(NewConversationTabRequest(agentSession: record, pane: pane.handle))

        // The publisher's own per-workspace cache, kept between reads as the running app keeps it.
        let cache = ControlWorkspaceInfoCache()
        func shown() -> String? {
            ControlSnapshotPublisher.topology(services, cache: cache).workspaces
                .flatMap(\.panes).flatMap(\.tabs).first { $0.surface == created.surface.description }?.agentSessionID
        }
        await until { shown() == "chat-first" }
        #expect(shown() == "chat-first")

        // The person picks another chat in the tab: the page's bind.
        _ = try await connection.request(BindConversationTabSessionRequest(surface: created.surface, session: "chat-picked", expectedSession: "chat-first"))
        await until {
            services.daemon.store.workspaces.flatMap { $0.screens.flatMap { $0.panes.flatMap(\.tabs) } }
                .first { $0.surface == created.surface }?.agentSession?.session == "chat-picked"
        }
        await until { shown() == "chat-picked" }
        #expect(shown() == "chat-picked", "the control snapshot still names the chat the tab first showed")
    }
}

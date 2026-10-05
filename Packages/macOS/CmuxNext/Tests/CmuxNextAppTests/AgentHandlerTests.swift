import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// Cmd-I must use the shared workspace creation path when the active
/// workspace has not mounted a pane yet, then open a real agent tab in the
/// pane that path creates.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentHandlerTests {
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(15))
        while !condition(), clock.now < end { try await clock.sleep(for: .milliseconds(20)) }
    }

    @Test func newAgentChatCreatesWorkspaceAndOpensChatWhenNoPaneIsMounted() async throws {
        let daemon = try TopologyDaemon(emptyWorkspace: true)
        let services = ActionBindingCoverageTests.boundServices()
        // Leave the initial empty workspace alone so Cmd-I's own tracked
        // `newTab` work is the path that creates the first usable pane.
        services.emptyWorkspaces.canCreate = { false }
        services.daemon.start(makeConnection: { daemon.connection() })
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            services.daemon.shutdownConnection()
            daemon.stop()
        }

        try await Self.waitUntil { services.daemon.store.isLoaded && services.daemon.store.workspaces.count == 1 }
        let window = try #require(services.windows.openWindow(workspaces: [TopologyDaemon.firstKey]))
        services.windows.didActivate(window)
        services.windows.reconcileMembership()
        try await Self.waitUntil { window.content != nil }
        #expect(window.content?.panes.isEmpty == true)

        let run = RegistryControlBridge(registry: services.registry).performActionTracked(ControlActionRequest(
            actionID: "palette.newAgentChat", origin: "user", focus: true
        ))
        #expect(run.outcome == .ran, "Cmd-I: \(run.outcome)")
        for task in run.work { #expect(await task.value == nil, "Cmd-I work") }

        try await Self.waitUntil {
            guard let pane = window.content?.panes.values.first else { return false }
            return pane.pane.tabs.count == 1 && pane.pane.tabs[0].agentSession != nil
        }
        let pane = try #require(window.content?.panes.values.first)
        #expect(pane.pane.tabs.count == 1)
        let tab = try #require(pane.pane.tabs.first)
        #expect(tab.agentSession != nil)
        #expect(pane.stripModel.selectedID?.rawValue == tab.id)
        #expect(window.state.workspaceID == TopologyDaemon.firstKey)
        let commands = daemon.commands.names.withLock { $0 }
        #expect(commands.contains("create-terminal"))
        #expect(!commands.contains("create-workspace"), "Cmd-I must repair the active workspace, not create a different one")
    }
}

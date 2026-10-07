import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// A person's New Agent Chat (Cmd-I, the menu, the palette) opens a new
/// workspace whose only tab is the chat, like a new thread in the Codex
/// and Claude desktop apps (lawrence-call-1006 D). No terminal is created
/// for it, and the focused pane gets no tab. Scripts keep the old
/// contract: `palette.newAgentChat` from the CLI opens a tab in the pane.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentChatNewWorkspaceTests {
    private static func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                                  _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(15), sourceLocation: sourceLocation, condition)
    }

    /// Bound services on a topology daemon whose one workspace shows a pane,
    /// with in-pane chat creations recorded instead of sent.
    private struct Fixture {
        let daemon: TopologyDaemon
        let services: AppServices
        let window: WindowController
        let paneCreations: Box

        @MainActor final class Box { var panes: [PaneID] = [] }

        func stop() {
            for controller in services.windows.controllers { controller.window?.close() }
            services.daemon.shutdownConnection()
            daemon.stop()
        }
    }

    private func start() async throws -> Fixture {
        // New Agent Chat sends new-conversation-tab, which needs conversation-tabs.
        let daemon = try TopologyDaemon(extraCapabilities: [DaemonCapabilities.shared.conversationTabs])
        let services = ActionBindingCoverageTests.boundServices()
        let box = Fixture.Box()
        services.agentTabs.localHost = AgentTabFixture.host
        services.agentTabs.holdsTabs = { _ in true }
        services.agentTabs.create = { pane, _, _, _, _ in
            box.panes.append(pane)
            throw CancellationError()
        }
        services.daemon.start(makeConnection: { daemon.connection() })
        try await Self.waitUntil { services.daemon.store.isLoaded && services.daemon.store.workspaces.count == 1 }
        let window = try #require(services.windows.openWindow(workspaces: [TopologyDaemon.firstKey]))
        services.windows.didActivate(window)
        services.windows.reconcileMembership()
        try await Self.waitUntil { window.content?.panes.isEmpty == false }
        return Fixture(daemon: daemon, services: services, window: window, paneCreations: box)
    }

    private func newAgentChat(_ fixture: Fixture, origin: String) {
        let run = RegistryControlBridge(registry: fixture.services.registry).performActionTracked(ControlActionRequest(
            actionID: "palette.newAgentChat", origin: origin, focus: true
        ))
        #expect(run.outcome == .ran, "New Agent Chat: \(run.outcome)")
    }

    @Test func aPersonsNewAgentChatOpensAWorkspaceWithOnlyTheChat() async throws {
        let fixture = try await start()
        defer { fixture.stop() }

        newAgentChat(fixture, origin: "user")

        let commands = fixture.daemon.commands
        try await Self.waitUntil("the chat is created in a new workspace") {
            commands.names.withLock { $0.contains("new-conversation-tab") }
        }
        let sent = commands.names.withLock { $0 }
        let created = try #require(sent.firstIndex(of: "create-workspace"), "no workspace was created: \(sent)")
        let chat = try #require(sent.firstIndex(of: "new-conversation-tab"), "no chat was created: \(sent)")
        #expect(created < chat)
        #expect(!sent.contains("create-terminal"), "the chat's workspace needs no terminal")
        #expect(fixture.paneCreations.panes.isEmpty, "the focused pane must not get a chat tab")
        try await Self.waitUntil("the window shows the new workspace") {
            fixture.window.state.workspaceID.map { $0 != TopologyDaemon.firstKey } == true
        }
    }

    @Test func aScriptsNewAgentChatStillOpensATabInThePane() async throws {
        let fixture = try await start()
        defer { fixture.stop() }
        let pane = try #require(fixture.window.content?.panes.values.first)

        newAgentChat(fixture, origin: "cli")

        try await Self.waitUntil("the chat tab is created in the pane") { !fixture.paneCreations.panes.isEmpty }
        #expect(fixture.paneCreations.panes == [pane.pane.handle])
        #expect(!fixture.daemon.commands.names.withLock { $0.contains("create-workspace") })
    }
}

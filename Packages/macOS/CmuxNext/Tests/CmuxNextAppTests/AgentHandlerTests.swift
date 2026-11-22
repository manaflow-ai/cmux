import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// Cmd-I must use the shared workspace creation path when the active
/// workspace has not mounted a pane yet, then open an agent chat tab in the
/// pane that path creates. The tab is a store conversation tab: it shows at
/// once as the store's provisional tab while `new-conversation-tab` is held.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentHandlerTests {
    /// Waits up to 15 s; a timeout records an Issue at the caller (``waitForCondition``).
    private static func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                                  _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(15), sourceLocation: sourceLocation, condition)
    }

    /// New Agent Chat and Add Harness… (BYOH H3) share the pane path: both work from Home or a
    /// workspace with no mounted pane yet (nxdog proof: Add Harness refused "No pane is focused").
    @Test(arguments: ["palette.newAgentChat", "palette.addHarness"])
    func newAgentChatCreatesWorkspaceAndOpensChatWhenNoPaneIsMounted(_ actionID: String) async throws {
        let daemon = try TopologyDaemon(emptyWorkspace: true)
        let services = ActionBindingCoverageTests.boundServices()
        // Leave the initial empty workspace alone so Cmd-I's own tracked
        // `newTab` work is the path that creates the first usable pane.
        services.emptyWorkspaces.canCreate = { false }
        // The topology daemon has no agent session tabs; the app's create waits until the end.
        let creations = HeldAgentTabCreations()
        services.agentTabs.localHost = AgentTabFixture.host
        services.agentTabs.holdsTabs = { _ in true }
        services.agentTabs.create = { pane, _, _, _, _ in try await creations.hold(pane) }
        services.daemon.start(makeConnection: { daemon.connection() })
        defer {
            creations.release()
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
            actionID: actionID, origin: "user", focus: true
        ))
        #expect(run.outcome == .ran, "\(actionID): \(run.outcome)")
        for task in run.work {
            let failure = await task.value
            #expect(failure == nil, "Cmd-I work: \(failure.map(String.init(describing:)) ?? "")")
        }

        func agentTabs(_ pane: PaneController) -> [TabModel] { pane.pane.tabs.filter { $0.agentSession != nil } }
        try await Self.waitUntil {
            guard let pane = window.content?.panes.values.first else { return false }
            return agentTabs(pane).count == 1
        }
        let pane = try #require(window.content?.panes.values.first)
        let tabs = agentTabs(pane)
        #expect(tabs.count == 1)
        #expect(ProvisionalTab.isProvisional(tabs[0].id), "the chat shows before the store answers")
        #expect(creations.panes == [pane.pane.handle], "the store creation targets the pane Cmd-I created")
        #expect(pane.stripModel.selectedID?.rawValue == tabs[0].id)
        #expect(window.state.workspaceID == TopologyDaemon.firstKey)
        let commands = daemon.commands.names.withLock { $0 }
        #expect(commands.contains("create-terminal"))
        #expect(!commands.contains("create-workspace"), "Cmd-I must repair the active workspace, not create a different one")
    }
}

/// `new-conversation-tab` calls held until the test ends; each then fails, which drops its tab.
@MainActor private final class HeldAgentTabCreations {
    private(set) var panes: [PaneID] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func hold(_ pane: PaneID) async throws -> (created: AgentTabCreated, sequence: UInt64?) {
        panes.append(pane)
        if !released { await withCheckedContinuation { waiting.append($0) } }
        throw CancellationError()
    }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

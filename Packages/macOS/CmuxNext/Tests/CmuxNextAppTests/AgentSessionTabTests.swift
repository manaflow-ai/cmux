import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// `agent.openSessionTab` (MCP `app_agent_open_tab`, `cmux agent open-tab`): an agent opens an
/// existing acpmux session's chat as a tab of a pane it names, the way the cmux-subsessions
/// instructions tell it to show a sub-session's chat, without a new workspace. Before it, the only
/// way was `agent.openSessionWorkspace`, which always made a workspace.
@MainActor @Suite(.serialized)
struct AgentSessionTabTests {
    /// The tabs the store was asked to create: (pane, the session record).
    @MainActor final class Made {
        var tabs: [(PaneID, AgentSessionRef)] = []
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"session-tab-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Services with one connected workspace whose store takes agent tabs; `create` records each one.
    private static func services(_ made: Made) throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try connected())
        store.apply(snapshot: tree())
        let tabs = services.agentTabs
        tabs.localHost = AgentSessionRef.host(installID: "session-tab-test")
        tabs.holdsTabs = { _ in true }
        tabs.reachable = { _ in true }
        tabs.create = { pane, _, record, _, _, _ in
            made.tabs.append((pane, record))
            return (AgentTabCreated(key: "tab-\(record.session ?? "")", surface: SurfaceID(rawValue: 9)), nil)
        }
        AppActions.bind(services)
        return services
    }

    @Test func aScriptOpensASessionsChatAsATabOfThePaneItNames() async throws {
        let made = Made()
        let services = try Self.services(made)
        try #require(services.agentTabs.canHostChat, "this build has no agent page")
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id),
                                          arguments: ["session": .string("s-child")], origin: .script)
        let refusal = services.registry.capturingRefusal {
            #expect(services.registry.perform("agent.openSessionTab", invocation: invocation))
        }
        #expect(refusal == nil, "refused: \(refusal ?? "")")
        let deadline = ContinuousClock.now + .seconds(2)
        while made.tabs.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(made.tabs.count == 1)
        #expect(made.tabs.first?.0 == pane.handle, "the tab went to another pane")
        #expect(made.tabs.first?.1.session == "s-child", "the tab is not bound to the session")
    }

    @Test func noSessionIsRefusedAndOpensNothing() throws {
        let made = Made()
        let services = try Self.services(made)
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id),
                                          arguments: ["session": .string("  ")], origin: .script)
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("agent.openSessionTab", invocation: invocation)
        }
        #expect(refusal == MiscHandlerStrings.sessionRequired)
        #expect(made.tabs.isEmpty)
    }
}

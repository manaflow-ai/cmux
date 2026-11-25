import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
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
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: AgentChatActionFixture.environment)
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

    @Test(arguments: [true, false])
    func peerOpenWhenCreateRepliesBeforeTheTabIsListed(focus: Bool) async throws {
        let made = Made()
        let services = try Self.services(made)
        let store = services.daemon.store
        let workspace = try #require(store.workspaces.first)
        services.windows.ordersWindowsIn = false
        let windowID = "open-peer-window"
        _ = services.windows.registry.apply { $0.openWindow(id: windowID, workspaceIDs: [workspace.id]) }
        let window = services.windows.makeController(for: try #require(services.windows.registry.value.window(windowID)))
        defer { window.teardown(); window.window?.close() }
        window.state.showWorkspace(workspace.id)
        window.showWorkspace(requested: workspace.id)
        let pane = try #require(window.focusedPane)
        let original = try #require(pane.stripModel.selectedID?.rawValue)

        let session = UUID().uuidString
        let peer = "peer-\(session)"
        services.agentLanes.set(session, AgentActivityLane(id: session, name: "\(peer)/chat", title: "Chat", peer: peer,
                                                         parent: nil, state: .idle, since: nil, error: nil))
        defer { services.agentLanes.set(session, nil) }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.pane.id),
                                          arguments: ["session": .string("chat"), "host": .string(peer)], origin: .cli, focusRequested: focus)
        let run = services.registry.capturingRun {
            #expect(services.registry.perform("agent.openSessionTab", invocation: invocation))
        }
        let result = try #require(run.results.first)
        let fields = try await result.value.get()
        let key = "tab-\(session)"
        #expect(fields["tab"] == .string(key))
        #expect(store.tab(id: key) == nil)
        let standIn = try #require(pane.pane.tabs.first { ProvisionalTab.isProvisional($0.id) })
        #expect(pane.stripModel.selectedID?.rawValue == (focus ? standIn.id : original))

        // Deliver the daemon tree only after the action has returned the durable tab id.
        var tree = Self.tree()
        var chat = TabSnapshot(surface: 9, tabResourceID: ResourceID(rawValue: key), kind: .conversation)
        chat.conversation = ConversationTabRef(agentSession: try #require(made.tabs.first?.1))
        tree.workspaces[0].screens[0].panes[0].tabs.append(chat)
        store.apply(snapshot: tree)
        pane.syncStripFromStore()
        #expect(pane.stripModel.selectedID?.rawValue == (focus ? key : original))
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

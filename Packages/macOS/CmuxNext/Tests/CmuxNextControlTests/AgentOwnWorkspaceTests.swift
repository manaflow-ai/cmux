@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// An agent's tabs open in its own workspace, never in the focused one (Home), unless it names
/// Home by id (user, 2026-11-18: "workspace agent is making browser tabs in home workspace,
/// rather than its own workspace"). The person looks at Home; the agent's chat is in its own
/// workspace, or its chat tab is closed and only its session's workspace key
/// (`CMUX_WORKSPACE_ID`, `caller.workspace`) says where it runs.
@Suite(.timeLimit(.minutes(1))) struct AgentOwnWorkspaceTests {
    /// The agent's workspace key, as acpmux sets `CMUX_WORKSPACE_ID` (upper case, dashed).
    static let agentKey = "2487AED7-EDE0-435B-85BE-EA666881E9AD"

    /// Home (focused: the person looks at its right column) and the agent's workspace, whose
    /// first pane holds the agent's chat (`agent-a`) and a terminal.
    static func snapshot() -> ControlSnapshot {
        var snapshot = ControlSnapshot()
        let url = ControlArgumentInfo(name: "url", title: "URL", kind: .string, isRequired: false)
        func action(_ id: String, _ targets: [String], _ arguments: [ControlArgumentInfo] = []) -> ControlActionInfo {
            ControlActionInfo(id: id, title: id, category: "tab", categoryTitle: "Tabs", cliName: id, symbol: "globe", keywords: [],
                              shortcut: nil, shortcutConfig: nil, arguments: arguments, targets: targets, requiresMask: 0, requires: [],
                              isBound: true, isDebugOnly: false, mainMenu: nil)
        }
        snapshot.catalog = ControlCatalog(actions: [action("openBrowser", ["tab"], [url]), action("openBrowser.chromium", ["tab"], [url]),
                                                    action("new.browser.tab", ["pane"], [url]), action("palette.open", []),
                                                    action("file.open", ["pane"], [ControlArgumentInfo(name: "path", title: "Path", kind: .string, isRequired: false)])],
                                          contextMask: 0, aliases: [:],
                                          targetKinds: ["tab", "tab-group", "pane", "column", "screen", "workspace", "workspace-group", "window"],
                                          debugActionsAvailable: true)
        var topology = ControlTopology()
        topology.isLoaded = true
        topology.daemonState = "connected"
        var homeChat = ControlTabInfo(id: "tab-home", surface: "31", kind: "conversation", title: "Home")
        homeChat.page = "home-dock"
        var dock = ControlPaneInfo(id: "pane-home", handle: "8", selectedTabID: "tab-home", tabs: [homeChat])
        dock.column = 0
        dock.dock = "left"
        var right = ControlPaneInfo(id: "pane-right", handle: "9", selectedTabID: "tab-right",
                                    tabs: [ControlTabInfo(id: "tab-right", surface: "32", kind: "browser", title: "Docs")])
        right.column = 1
        var home = ControlWorkspaceInfo(id: "044cecad-ad6c-4d04-b183-24f9b9308c1f", handle: "10", name: "Home",
                                        screens: [ControlScreenInfo(id: "screen-home", handle: "11", panes: [dock, right])])
        home.kind = "home"
        home.resourceID = "ws_home"
        var chat = ControlTabInfo(id: "tab-chat", surface: "41", kind: "conversation", title: "Agent")
        chat.agentSessionID = "agent-a"
        let terminal = ControlTabInfo(id: "tab-term", surface: "42", kind: "terminal", title: "zsh", terminalID: "term-a")
        var chatPane = ControlPaneInfo(id: "pane-agent", handle: "12", selectedTabID: "tab-chat", tabs: [chat, terminal])
        chatPane.column = 0
        var screen = ControlScreenInfo(id: "screen-agent", handle: "13", panes: [chatPane])
        screen.defaultPaneID = "pane-agent"
        var agent = ControlWorkspaceInfo(id: agentKey.lowercased(), handle: "14", name: "Agent work", screens: [screen])
        agent.resourceID = "ws_agent"
        topology.workspaces = [home, agent]
        topology.windows = [ControlWindowInfo(id: "win-1", workspaceID: home.id, isKey: true, isVisible: true, focusedPaneID: "pane-right")]
        topology.focus = ControlFocus(windowID: "win-1", workspaceID: home.id, paneID: "pane-right", tabID: "tab-right")
        snapshot.topology = topology
        return snapshot
    }

    func makeRouter(_ executor: OpenBrowserExecutor, snapshot: ControlSnapshot = Self.snapshot()) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = snapshot }
        executor.router.withLock { $0 = router }
        return router
    }

    func run(_ router: ControlRouter, _ action: String, caller: JSONValue) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": .string(action), "args": ["url": "https://example.com"], "caller": caller,
        ]))
    }

    /// The workspace (its public id) that holds the pane or tab `target` names.
    func workspace(of target: ControlTargetRef?, in snapshot: ControlSnapshot = Self.snapshot()) -> String? {
        guard let target else { return nil }
        for workspace in snapshot.topology.workspaces {
            for pane in workspace.panes where pane.id == target.id || pane.tabs.contains(where: { $0.id == target.id }) {
                return workspace.publicID
            }
        }
        return nil
    }

    @Test func anAgentsEngineBrowserOpensInItsOwnWorkspaceNotTheFocusedHome() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        _ = try await run(router, "openBrowser.chromium", caller: ["agent_session": "agent-a"]).get()
        let request = try #require(executor.all.first)
        #expect(workspace(of: request.target) == "ws_agent", "\(String(describing: request.target))")
        #expect(request.besideCaller)
    }

    @Test func anAgentsPaneActionOpensInItsOwnWorkspace() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        _ = try await run(router, "new.browser.tab", caller: ["agent_session": "agent-a"]).get()
        let request = try #require(executor.all.first)
        #expect(workspace(of: request.target) == "ws_agent", "\(String(describing: request.target))")
    }

    @Test func anAgentWhoseChatTabIsClosedOpensInTheWorkspaceItsSessionRunsIn() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        _ = try await run(router, "openBrowser", caller: ["agent_session": "agent-closed", "workspace": .string(Self.agentKey)]).get()
        let request = try #require(executor.all.first)
        #expect(workspace(of: request.target) == "ws_agent", "\(String(describing: request.target))")
    }

    @Test func anAgentWithNoChatAndNoWorkspaceIsRefusedNeverSentToHome() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        let result = await run(router, "openBrowser", caller: ["agent_session": "agent-closed", "workspace": "00000000-0000-0000-0000-000000000000"])
        let failure = try #require(result.failure)
        #expect(failure.code == "caller_unavailable")
        #expect(executor.all.isEmpty)
    }

    @Test func identifyPlacesAnAgentWhoseChatTabIsClosedInItsOwnWorkspace() async throws {
        let router = makeRouter(OpenBrowserExecutor())
        let reply = try await router.handle(ControlRequest(id: "1", method: "system.identify", params: [
            "caller": ["agent_session": "agent-closed", "workspace": .string(Self.agentKey)],
        ])).get()
        #expect(reply["caller"]?["workspace"] == "ws_agent", "\(String(describing: reply["caller"]))")
    }

    /// `cmux open FILE` from an agent (`file.open` with its caller) opens in the agent's own
    /// workspace, also when no tab shows its chat; before, it opened in the focused pane, Home.
    @Test(arguments: [JSONValue.object(["agent_session": "agent-a"]),
                      .object(["agent_session": "agent-closed", "workspace": .string(agentKey)])])
    func anAgentsFileOpensInItsOwnWorkspace(caller: JSONValue) async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        let reply = try await router.handle(ControlRequest(id: "1", method: "file.open", params: [
            "path": "/tmp/note.md", "caller": caller,
        ])).get()
        let request = try #require(executor.all.first)
        #expect(workspace(of: request.target) == "ws_agent", "\(String(describing: request.target))")
        // The reply says where it opened: beside its caller, never "focused_pane" (Home).
        #expect(reply["placement"] == "caller", "\(reply)")
        #expect(reply["pane_id"] == .string(request.target?.id ?? "?"), "\(reply)")
    }

    @Test func aChiefTurnStillOpensBesideTheHomeChat() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        _ = try await run(router, "openBrowser", caller: ["agent_session": "turn-1", "home_chat": true,
                                                          "workspace": .string(Self.agentKey)]).get()
        let request = try #require(executor.all.first)
        #expect(request.target == ControlTargetRef(kind: "tab", id: "tab-right"), "\(String(describing: request.target))")
    }
}

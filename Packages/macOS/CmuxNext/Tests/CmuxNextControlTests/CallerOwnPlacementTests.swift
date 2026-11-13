@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Lawrence 2026-11-12: agents made tabs, browsers, diff viewers and terminals outside their own workspace,
/// in the workspace the person had focused or in Home (`cmux open` answered `"placement":"focused_pane"` 54
/// times in 14 days of transcripts). What a caller runs without naming a place stays in the caller's own
/// workspace: beside an agent (its helper column, else a new column right of it; never a column that is
/// another agent's home), in the own pane of a terminal no agent runs in, and never where the app's focus is.
///
/// The person works in `ws-1` (shown, `pane-1` focused). The caller is in `ws-agent`, which no window shows
/// unless a test says so.
@Suite(.timeLimit(.minutes(1))) struct CallerOwnPlacementTests {
    static let agent: JSONValue = ["terminal_id": "term-agent"]

    static func action(_ id: String, _ targets: [String], arguments: [String] = []) -> ControlActionInfo {
        ControlActionInfo(id: id, title: id, category: "tab", categoryTitle: "Tabs", cliName: "action " + id, symbol: "globe", keywords: [],
                          shortcut: nil, shortcutConfig: nil,
                          arguments: arguments.map { ControlArgumentInfo(name: $0, title: $0, kind: .string, isRequired: false) },
                          targets: targets, requiresMask: 0, requires: [], isBound: true, isDebugOnly: false, mainMenu: nil)
    }

    static func catalog() -> ControlCatalog {
        ControlCatalog(actions: [
            action("openBrowser", ["tab"], arguments: ["url"]), action("tab.focus", ["tab"]),
            action("file.open", ["pane"], arguments: ["path", "where"]),
            action("newSurface", ["tab"], arguments: ["cwd"]), action("splitRight", ["pane"]), action("renameTab", ["tab"]),
            action("renameWorkspace", ["workspace"]), action("closeTab", ["tab"]), action("commandPalette", []),
            action("newTab", ["workspace"]), action("newTab.default", ["tab"], arguments: ["cwd"]),
        ], contextMask: 0, aliases: [:], targetKinds: ["tab", "tab-group", "pane", "column", "screen", "workspace", "workspace-group", "window"],
                       debugActionsAvailable: true)
    }

    static func pane(_ id: String, _ tabs: [ControlTabInfo]) -> ControlPaneInfo {
        ControlPaneInfo(id: id, handle: id, selectedTabID: tabs.first?.id, tabs: tabs)
    }

    static func browser(_ id: String) -> ControlTabInfo {
        ControlTabInfo(id: id, surface: id, kind: "browser", title: id, url: "https://\(id).example/")
    }

    /// A terminal `agent` runs in (nil: a person's shell).
    static func terminal(_ id: String, _ terminal: String, agent: String?) -> ControlTabInfo {
        var tab = ControlTabInfo(id: id, surface: id, kind: "terminal", title: agent ?? "zsh", terminalID: terminal, cwd: "/work/" + id)
        tab.agent = agent
        tab.agentState = agent == nil ? nil : "working"
        return tab
    }

    static func chat(_ id: String, session: String) -> ControlTabInfo {
        var tab = ControlTabInfo(id: id, surface: id, kind: "conversation", title: "Agent")
        tab.agentSessionID = session
        return tab
    }

    /// `ws-agent`: the caller's pane (`own`, column 0) and `right` (column 1).
    static func snapshot(own: ControlTabInfo = terminal("tab-agent", "term-agent", agent: "claude"), right: [ControlPaneInfo] = [],
                         shown: Bool = false) -> ControlSnapshot {
        var snapshot = BrowserOpenSplitTests.snapshot()
        snapshot.catalog = catalog()
        var caller = pane("pane-agent", [own])
        caller.column = 0
        var columns = right
        for index in columns.indices { columns[index].column = 1 }
        var workspace = ControlWorkspaceInfo(id: "ws-agent", handle: "63", name: "Agent",
                                             screens: [ControlScreenInfo(id: "screen-agent", handle: "62", panes: [caller] + columns)])
        workspace.resourceID = "ws_agent"
        snapshot.topology.workspaces.append(workspace)
        if shown {
            snapshot.topology.windows.append(ControlWindowInfo(id: "win-2", workspaceID: "ws-agent", isKey: false, isVisible: true,
                                                               focusedPaneID: "pane-agent"))
        }
        return snapshot
    }

    func install(_ snapshot: ControlSnapshot) -> (ControlRouter, OpenBrowserExecutor) {
        let executor = OpenBrowserExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = snapshot }
        executor.router.withLock { $0 = router }
        return (router, executor)
    }

    /// One `action.run` with `caller` and no target; the request the app's handler got.
    func run(_ action: String, _ snapshot: ControlSnapshot, caller: JSONValue = Self.agent,
             args: [String: JSONValue] = [:]) async throws -> ControlActionRequest {
        let (router, executor) = install(snapshot)
        _ = try await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": .string(action), "args": .object(args), "caller": caller,
        ])).get()
        return try #require(executor.all.first)
    }

    static func tabTarget(_ id: String) -> ControlTargetRef { ControlTargetRef(kind: "tab", id: id) }
    static func paneTarget(_ id: String) -> ControlTargetRef { ControlTargetRef(kind: "pane", id: id) }

    // MARK: A surface an agent opens goes beside it

    @Test func anAgentTerminalsBrowserOpensInItsHelperColumn() async throws {
        let right = [Self.pane("pane-web", [Self.browser("tab-web")])]
        let request = try await run("openBrowser", Self.snapshot(right: right), args: ["url": "https://example.com"])
        #expect(request.target == Self.tabTarget("tab-web"), "the column right of its terminal: \(String(describing: request.target))")
        #expect(request.besideCaller)
        #expect(!request.newColumnBeside)
    }

    @Test func aShownAgentTerminalLetsTheAppMeasureItsHelperColumn() async throws {
        let right = [Self.pane("pane-web", [Self.browser("tab-web")])]
        let request = try await run("openBrowser", Self.snapshot(right: right, shown: true), args: ["url": "https://example.com"])
        // Its own tab with newColumnBeside: the app measures the column and places the tab there, as for a chat.
        #expect(request.target == Self.tabTarget("tab-agent"), "\(String(describing: request.target))")
        #expect(request.besideCaller)
        #expect(request.newColumnBeside)
    }

    @Test func withNoHelperColumnAnAgentTerminalsBrowserGetsANewColumnRightOfIt() async throws {
        let request = try await run("openBrowser", Self.snapshot(), args: ["url": "https://example.com"])
        #expect(request.target == Self.tabTarget("tab-agent"), "never the focused pane: \(String(describing: request.target))")
        #expect(request.besideCaller)
        #expect(request.newColumnBeside)
    }

    @Test(arguments: ["a terminal an agent runs in", "another agent's chat"])
    func aColumnThatIsAnotherAgentsHomeIsNeverTheHelperColumn(neighbor: String) async throws {
        let other = neighbor == "another agent's chat" ? Self.chat("tab-other", session: "agent-2")
            : Self.terminal("tab-other", "term-other", agent: "codex")
        let request = try await run("openBrowser", Self.snapshot(right: [Self.pane("pane-other", [other])]), args: ["url": "https://example.com"])
        #expect(request.target == Self.tabTarget("tab-agent"), "a new column right of the caller, not \(neighbor): \(String(describing: request.target))")
        #expect(request.newColumnBeside)
        #expect(request.besideCaller)
    }

    @Test func aTerminalWithNoAgentKeepsTheTabInItsOwnPane() async throws {
        let shell = Self.terminal("tab-agent", "term-agent", agent: nil)
        let right = [Self.pane("pane-web", [Self.browser("tab-web")])]
        let request = try await run("openBrowser", Self.snapshot(own: shell, right: right), args: ["url": "https://example.com"])
        #expect(request.target == Self.tabTarget("tab-agent"), "a person's shell: its own pane, not the focused one: \(String(describing: request.target))")
        #expect(!request.besideCaller)
        #expect(!request.newColumnBeside)
    }

    @Test func anAgentsNewTerminalOpensBesideItInItsOwnFolder() async throws {
        let right = [Self.pane("pane-web", [Self.browser("tab-web")]), Self.pane("pane-shell", [Self.terminal("tab-shell", "term-shell", agent: nil)])]
        let request = try await run("newSurface", Self.snapshot(right: right))
        #expect(request.target == Self.tabTarget("tab-shell"), "the helper column's pane that holds a terminal: \(String(describing: request.target))")
        #expect(request.besideCaller)
        #expect(request.arguments["cwd"] == .string("/work/tab-agent"))
    }

    // MARK: file.open and browser.open_split

    @Test func anAgentChatsFileOpensBesideItNotInTheFocusedPane() async throws {
        var snapshot = Self.snapshot(own: Self.chat("tab-agent", session: "agent-1"))
        let (router, executor) = install(snapshot)
        let reply = try await router.handle(ControlRequest(id: "1", method: "file.open", params: [
            "path": "/tmp/site/index.html", "caller": ["agent_session": "agent-1"],
        ])).get()
        let request = try #require(executor.all.first)
        #expect(request.actionID == "file.open")
        #expect(request.target == Self.paneTarget("pane-agent"), "\(String(describing: request.target))")
        #expect(request.besideCaller)
        #expect(request.newColumnBeside)
        #expect(reply["placement"] == "beside_caller_new_column")

        snapshot = Self.snapshot(own: Self.chat("tab-agent", session: "agent-1"), right: [Self.pane("pane-web", [Self.browser("tab-web")])])
        let (withColumn, columnExecutor) = install(snapshot)
        let beside = try await withColumn.handle(ControlRequest(id: "1", method: "file.open", params: [
            "path": "/tmp/site/index.html", "caller": ["agent_session": "agent-1"],
        ])).get()
        #expect(columnExecutor.all.first?.target == Self.paneTarget("pane-web"))
        #expect(columnExecutor.all.first?.besideCaller == true)
        #expect(beside["placement"] == "beside_caller")
    }

    @Test func aFileFromATerminalFollowsTheSameRule() async throws {
        let (router, executor) = install(Self.snapshot())
        let agent = try await router.handle(ControlRequest(id: "1", method: "file.open", params: ["path": "/tmp/a.md", "terminal_id": "term-agent"])).get()
        #expect(executor.all.first?.target == Self.paneTarget("pane-agent"))
        #expect(executor.all.first?.newColumnBeside == true)
        #expect(agent["placement"] == "beside_caller_new_column")

        let (plain, plainExecutor) = install(Self.snapshot(own: Self.terminal("tab-agent", "term-agent", agent: nil)))
        let shell = try await plain.handle(ControlRequest(id: "1", method: "file.open", params: ["path": "/tmp/a.md", "terminal_id": "term-agent"])).get()
        #expect(plainExecutor.all.first?.target == Self.paneTarget("pane-agent"))
        #expect(plainExecutor.all.first?.besideCaller == false)
        #expect(shell["placement"] == "caller_terminal")
        #expect(shell["pane_id"] == "pane-agent")
    }

    /// Open in the editor app opens nothing in cmux, so the run names no pane (a pane no window shows would refuse it).
    @Test func aFileForTheEditorAppIsNotPlaced() async throws {
        let request = try await run("file.open", Self.snapshot(), args: ["path": "/tmp/a.txt", "where": "editor"])
        #expect(request.target == nil)
        #expect(!request.besideCaller)
    }

    @Test func openSplitFromAnAgentTerminalGoesBesideItNotIntoItsOwnPane() async throws {
        let (router, executor) = install(Self.snapshot())
        let reply = try await router.handle(ControlRequest(id: "1", method: "browser.open_split", params: [
            "url": "https://example.com/", "terminal_id": "term-agent",
        ])).get()
        let request = try #require(executor.all.first)
        #expect(request.target == Self.tabTarget("tab-agent"))
        #expect(request.besideCaller)
        #expect(request.newColumnBeside)
        #expect(request.callerTerminal == "term-agent")
        #expect(reply["placement"] == "beside_caller_new_column")
        #expect(reply["workspace_id"] == "ws_agent")
    }

    // MARK: A run on an existing object uses the caller's own

    @Test(arguments: ["splitRight", "renameTab", "renameWorkspace"])
    func aTargetlessRunFromAnotherWorkspaceLandsInTheCallersNotTheFocusedOne(action: String) async throws {
        let own: [String: ControlTargetRef] = [
            "splitRight": Self.paneTarget("pane-agent"), "renameTab": Self.tabTarget("tab-agent"),
            "renameWorkspace": ControlTargetRef(kind: "workspace", id: "ws-agent"),
        ]
        for tab in [Self.terminal("tab-agent", "term-agent", agent: "claude"), Self.terminal("tab-agent", "term-agent", agent: nil)] {
            let snapshot = Self.snapshot(own: tab)
            #expect(snapshot.topology.focus.workspaceID == "ws-1", "the person's focus is in another workspace")
            let request = try await run(action, snapshot)
            #expect(request.target == own[action], "\(action): \(String(describing: request.target))")
        }
    }

    @Test func aGlobalActionAndAnExplicitTargetAreUnchanged() async throws {
        #expect(try await run("commandPalette", Self.snapshot()).target == nil)
        let (router, executor) = install(Self.snapshot())
        _ = try await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "openBrowser", "target": "tab:tab-3", "caller": Self.agent,
        ])).get()
        #expect(executor.all.first?.target == Self.tabTarget("tab-3"))
        #expect(executor.all.first?.besideCaller == false)
    }

    @Test func anAgentsTargetlessCloseIsRefusedAndAShellClosesItsOwnTab() async throws {
        let (router, executor) = install(Self.snapshot())
        let refused = await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "closeTab", "caller": Self.agent]))
        #expect(refused.failure?.code == "target_required")
        #expect(refused.failure?.data?["tab"] == "tab-agent")
        #expect(executor.all.isEmpty, "an agent's close with no target closed something")

        let shell = try await run("closeTab", Self.snapshot(own: Self.terminal("tab-agent", "term-agent", agent: nil)))
        #expect(shell.target == Self.tabTarget("tab-agent"), "never the person's focused tab: \(String(describing: shell.target))")
    }

    @Test func anAgentTheTopologyDoesNotShowIsRefusedAndAnUnknownTerminalIsLeftAlone() async throws {
        let (router, executor) = install(Self.snapshot())
        let refused = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "splitRight", "caller": ["agent_session": "gone"],
        ]))
        #expect(refused.failure?.code == "caller_unavailable")
        #expect(executor.all.isEmpty)
        // Another session's terminal: the app cannot place it, so the run is as before.
        #expect(try await run("splitRight", Self.snapshot(), caller: ["terminal_id": "term-elsewhere"]).target == nil)
        // A new workspace needs no place of the caller's: an agent no tab shows still makes one.
        #expect(try await run("newTab", Self.snapshot(), caller: ["agent_session": "gone"]).target == nil)
    }

    @Test func anAgentsNewTabOpensBesideItAndItsNewWorkspaceIsListedByItsOwn() async throws {
        let request = try await run("newTab.default", Self.snapshot())
        #expect(request.target == Self.tabTarget("tab-agent"))
        #expect(request.besideCaller)
        #expect(request.newColumnBeside)
        #expect(request.arguments["cwd"] == .string("/work/tab-agent"))
        #expect(try await run("newTab", Self.snapshot()).target == ControlTargetRef(kind: "workspace", id: "ws-agent"))
    }

    // MARK: system.identify reports the same decision

    func identify(_ snapshot: ControlSnapshot, caller: JSONValue? = Self.agent) async throws -> JSONValue {
        let (router, _) = install(snapshot)
        return try await router.handle(ControlRequest(id: "1", method: "system.identify", params: caller.map { ["caller": $0] } ?? [:])).get()
    }

    @Test func identifyMarksCallerPlacementWithAndWithoutACaller() async throws {
        #expect(try await identify(Self.snapshot())["caller_placement"] == JSONValue(2))
        #expect(try await identify(Self.snapshot(), caller: nil)["caller_placement"] == JSONValue(2))
    }

    @Test func identifyReportsTheHelperColumnOfAnAgentTerminal() async throws {
        let reply = try await identify(Self.snapshot(right: [Self.pane("pane-web", [Self.browser("tab-web")])]))
        #expect(reply["beside"]?["pane"] == "pane-web")
        #expect(reply["beside"]?["placement"] == "existing_column")
        #expect(reply["beside"]?["panes"] == [["id": "pane-web", "kinds": ["browser"]]])
    }

    @Test func identifyReportsANewColumnWhenTheRightColumnIsAnotherAgents() async throws {
        let other = Self.pane("pane-other", [Self.terminal("tab-other", "term-other", agent: "codex")])
        #expect(try await identify(Self.snapshot(right: [other]))["beside"] == ["pane": .null, "placement": "new_column"])
        #expect(try await identify(Self.snapshot())["beside"] == ["pane": .null, "placement": "new_column"])
    }

    @Test func identifyReportsTheOwnPaneOfATerminalWithNoAgent() async throws {
        let shell = Self.terminal("tab-agent", "term-agent", agent: nil)
        let reply = try await identify(Self.snapshot(own: shell, right: [Self.pane("pane-web", [Self.browser("tab-web")])]))
        #expect(reply["beside"] == ["pane": "pane-agent", "placement": "own_pane"], "\(String(describing: reply["beside"]))")
    }
}

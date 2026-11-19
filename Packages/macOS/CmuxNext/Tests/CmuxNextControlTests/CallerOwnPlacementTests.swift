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

    /// An action the catalog marks destructive (it then needs `confirm`).
    static func destructive(_ id: String, _ targets: [String], requires: [String] = [], naming: ControlArgumentInfo? = nil) -> ControlActionInfo {
        var info = action(id, targets)
        info.arguments = [ControlArgumentInfo(name: "confirm", title: "confirm", kind: .bool, isRequired: false)] + (naming.map { [$0] } ?? [])
        info.isDestructive = true
        info.requires = requires
        info.requiresMask = requires.isEmpty ? 0 : 1 << 1
        if !requires.isEmpty { info.category = "browser" }
        return info
    }

    static func catalog() -> ControlCatalog {
        ControlCatalog(actions: [
            action("openBrowser", ["tab"], arguments: ["url"]), action("tab.focus", ["tab"]),
            action("file.open", ["pane"], arguments: ["path", "where"]),
            action("newSurface", ["tab"], arguments: ["cwd"]), action("splitRight", ["pane"]), action("renameTab", ["tab"]),
            action("renameWorkspace", ["workspace"]), action("closeTab", ["tab"]), action("commandPalette", []),
            action("newTab", ["workspace"]), action("newTab.default", ["tab"], arguments: ["cwd"]),
            action("screen.rename", ["screen"]), destructive("screen.closeOthers", ["screen"]), destructive("tabGroup.close", ["tab-group"]),
            destructive("browser.pageInfo.deleteSiteData", ["pane"], requires: ["browserFocused"]),
            destructive("workspace.closeAll", [], naming: ControlArgumentInfo(name: "window", title: "Window", kind: .target, isRequired: false, targetKind: "window")),
            action("closeWindow", []), action("cloud.team.archive", ["workspace", "tab"], arguments: ["session"]),
            action("bookmark.remove", ["bookmark"], arguments: ["bookmark"]),
        ], contextMask: 1 << 1, aliases: [:], targetKinds: ["tab", "tab-group", "pane", "column", "screen", "workspace", "workspace-group", "window"],
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

    /// A browser from a terminal a window shows goes where a Cmd-click's would (TabLifecycle, Lawrence
    /// 2026-11-15): the run is aimed at the terminal's own tab with its caller, and the app picks the pane on
    /// its right, else a new pane beside it. An agent's terminal and a person's shell take the same path.
    @Test(arguments: [true, false])
    func aShownTerminalsBrowserIsAimedAtItsOwnTabForTheCmdClickRule(runsAgent: Bool) async throws {
        let right = [Self.pane("pane-other", [Self.terminal("tab-other", "term-other", agent: "codex")])]
        let own = Self.terminal("tab-agent", "term-agent", agent: runsAgent ? "claude" : nil)
        let request = try await run("openBrowser", Self.snapshot(own: own, right: right, shown: true), args: ["url": "https://example.com"])
        #expect(request.target == Self.tabTarget("tab-agent"), "\(String(describing: request.target))")
        #expect(request.callerTerminal == "term-agent")
        #expect(!request.besideCaller, "the app's Cmd-click rule decides, not the router")
        #expect(!request.newColumnBeside)
        #expect(request.besideAgentHomes == ["pane-other"], "the app is told which panes are another agent's")
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

    /// A person's shell: its new terminal is a tab in its own pane, shown or not, never in the focused one.
    @Test func aTerminalWithNoAgentKeepsItsNewTerminalInItsOwnPane() async throws {
        let shell = Self.terminal("tab-agent", "term-agent", agent: nil)
        let right = [Self.pane("pane-web", [Self.browser("tab-web")])]
        for shown in [true, false] {
            let terminal = try await run("newSurface", Self.snapshot(own: shell, right: right, shown: shown))
            #expect(terminal.target == Self.tabTarget("tab-agent"))
            #expect(!terminal.besideCaller)
        }
    }

    /// A terminal no window shows (the person looks at another workspace) has nothing for the app to measure:
    /// the router places its browser from the topology, as an agent chat's off screen. A plain shell and an
    /// agent's terminal alike, with no target or aimed at the terminal's own tab (the CLI's `browser open`):
    /// the pane of the column on its right, never another agent's column, else a new column right of it. Never
    /// a tab in the terminal's own pane (fleet capture of build ff3b87ce78d6, 2026-11-18).
    @Test(arguments: [true, false], [true, false])
    func anUnshownTerminalsBrowserIsPlacedFromTheTopology(runsAgent: Bool, aimedAtOwnTab: Bool) async throws {
        let own = Self.terminal("tab-agent", "term-agent", agent: runsAgent ? "claude" : nil)
        func open(_ right: [ControlPaneInfo]) async throws -> ControlActionRequest {
            let (router, executor) = install(Self.snapshot(own: own, right: right))
            var params: [String: JSONValue] = ["action": "openBrowser", "args": ["url": "https://example.com"], "caller": Self.agent]
            if aimedAtOwnTab { params["target"] = "tab:tab-agent" }
            _ = try await router.handle(ControlRequest(id: "1", method: "action.run", params: params)).get()
            return try #require(executor.all.first)
        }
        let helper = try await open([Self.pane("pane-web", [Self.browser("tab-web")])])
        #expect(helper.target == Self.tabTarget("tab-web"), "the column on its right: \(String(describing: helper.target))")
        #expect(helper.besideCaller)
        #expect(!helper.newColumnBeside)
        let alone = try await open([])
        #expect(alone.target == Self.tabTarget("tab-agent"))
        #expect(alone.besideCaller, "moved out of the terminal's own pane")
        #expect(alone.newColumnBeside)
        let taken = try await open([Self.pane("pane-other", [Self.chat("tab-other", session: "agent-2")])])
        #expect(taken.target == Self.tabTarget("tab-agent"), "never another agent's column: \(String(describing: taken.target))")
        #expect(taken.newColumnBeside)
        #expect(taken.besideAgentHomes == ["pane-other"])
    }

    /// The three browser entry points of a person's shell agree: `cmux browser open` (openBrowser), `cmux open
    /// URL` (browser.open_split) and `cmux browser tab new` (browser.page.new_tab). While a window shows the
    /// shell each is aimed at its own tab with its terminal as the caller, which the app opens right of the
    /// terminal; while none does each is moved into a new column right of it.
    @Test(arguments: [true, false])
    func aPlainShellsThreeBrowserEntryPointsAgree(shown: Bool) async throws {
        let shell = Self.terminal("tab-agent", "term-agent", agent: nil)
        let snapshot = Self.snapshot(own: shell, shown: shown)
        let direct = try await run("openBrowser", snapshot, args: ["url": "https://example.com"])
        let (router, executor) = install(snapshot)
        let reply = try await router.handle(ControlRequest(id: "1", method: "browser.open_split", params: [
            "url": "https://example.com/", "terminal_id": "term-agent",
        ])).get()
        let split = try #require(executor.all.first)
        #expect(reply["placement"] == "caller_terminal")
        let pageExecutor = OpenBrowserExecutor()
        let pages = ControlRouter(identity: testIdentity(), executor: pageExecutor, configuration: .loadTolerant)
        BrowserPageService(engine: BrowserCallerTargetTests.NoEngine()).install(on: pages)
        pages.snapshots.publish { $0 = snapshot }
        pageExecutor.router.withLock { $0 = pages }
        _ = try await pages.handle(ControlRequest(id: "1", method: "browser.page.new_tab", params: [
            "url": "https://example.com/", "caller": Self.agent,
        ])).get()
        let tab = try #require(pageExecutor.all.first)
        for request in [direct, split, tab] {
            #expect(request.actionID == "openBrowser")
            #expect(request.target == Self.tabTarget("tab-agent"), "\(String(describing: request.target))")
            #expect(request.callerTerminal == "term-agent")
            #expect(request.besideCaller == !shown)
            #expect(request.newColumnBeside == !shown)
            #expect(!request.background)
        }
    }

    // MARK: The cmux MCP server is always an agent

    /// A terminal whose hooks reported nothing is a person's shell for the app, but its MCP server's requests
    /// (`origin: mcp`) come from an agent: placed beside, and its targetless close is refused.
    @Test func aRequestFromTheMCPServerIsAnAgentsAlsoInATerminalWithNoHookReport() async throws {
        let shell = Self.terminal("tab-agent", "term-agent", agent: nil)
        let (router, executor) = install(Self.snapshot(own: shell))
        let refused = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "closeTab", "caller": Self.agent, "origin": "mcp",
        ]))
        #expect(refused.failure?.code == "target_required")
        #expect(executor.all.isEmpty)

        let file = try await router.handle(ControlRequest(id: "2", method: "file.open", params: [
            "path": "/tmp/a.md", "terminal_id": "term-agent", "origin": "mcp",
        ])).get()
        #expect(file["placement"] == "caller", "beside it, not in its own pane: \(file)")
        #expect(executor.all.first?.besideCaller == true)
        #expect(executor.all.first?.newColumnBeside == true)

        let (terminals, terminalExecutor) = install(Self.snapshot(own: shell))
        _ = try await terminals.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "newSurface", "caller": Self.agent, "origin": "mcp",
        ])).get()
        #expect(terminalExecutor.all.first?.besideCaller == true)

        // `origin: "mcp"` on the reads too: `beside` is never `own_pane` for the MCP server's caller.
        for method in ["system.identify", "snapshot.get"] {
            let reply = try await router.handle(ControlRequest(id: "3", method: method, params: ["caller": Self.agent, "origin": "mcp"])).get()
            #expect(reply["beside"] == ["pane": .null, "placement": "new_column"], "\(method): \(String(describing: reply["beside"]))")
        }
        let helper = Self.snapshot(own: shell, right: [Self.pane("pane-web", [Self.browser("tab-web")])])
        let (beside, _) = install(helper)
        let withColumn = try await beside.handle(ControlRequest(id: "4", method: "system.identify", params: ["caller": Self.agent, "origin": "mcp"])).get()
        #expect(withColumn["beside"]?["placement"] == "existing_column")
        #expect(try await beside.handle(ControlRequest(id: "5", method: "system.identify", params: ["caller": Self.agent])).get()["beside"]?["placement"] == "own_pane")
    }

    /// The pane the app splits off beside a caller is in the caller's own column (a screen stored as one split
    /// tree is column 0 everywhere): the layout's right neighbors name it (`rightPaneIDs`), so it is the helper
    /// column of the next open and of `system.identify`, not "nothing there" (fleet capture of build
    /// 76840bfee0ac, 2026-11-18: every open off screen made one more pane). A terminal's browser is a tab in the
    /// browser pane; its new terminal leaves the split below that lone pane to the app.
    @Test func aPaneSplitOffBesideTheCallerIsItsHelperColumn() async throws {
        func split(_ right: [ControlPaneInfo]) -> ControlSnapshot {
            var snapshot = Self.snapshot(right: right)
            snapshot.topology.workspaces = snapshot.topology.workspaces.map { workspace in
                guard workspace.id == "ws-agent" else { return workspace }
                var workspace = workspace
                workspace.screens = workspace.screens.map { screen in
                    var screen = screen
                    screen.panes = screen.panes.map { pane in
                        var pane = pane
                        pane.column = 0
                        pane.rightPaneIDs = pane.id == "pane-agent" ? right.map(\.id) : []
                        return pane
                    }
                    return screen
                }
                return workspace
            }
            return snapshot
        }
        let web = split([Self.pane("pane-web", [Self.browser("tab-web")])])
        let browser = try await run("openBrowser", web, args: ["url": "https://example.com"])
        #expect(browser.target == Self.tabTarget("tab-web"), "a tab in the pane split off beside it: \(String(describing: browser.target))")
        #expect(browser.besideCaller)
        #expect(!browser.newColumnBeside)
        let beside = try #require(try await identify(web)["beside"])
        #expect(beside["placement"] == "existing_column", "\(beside)")
        #expect(beside["pane"] == "pane-web")
        let terminal = try await run("newSurface", web)
        #expect(terminal.target == Self.tabTarget("tab-agent"), "the app splits below the lone browser pane: \(String(describing: terminal.target))")
        #expect(terminal.newColumnBeside)
        // Another agent's pane split off beside it is never its helper column.
        let other = split([Self.pane("pane-other", [Self.chat("tab-other", session: "agent-2")])])
        let taken = try await run("openBrowser", other, args: ["url": "https://example.com"])
        #expect(taken.target == Self.tabTarget("tab-agent"))
        #expect(taken.newColumnBeside)
        #expect(taken.besideAgentHomes == ["pane-other"])
        #expect(try await identify(other)["beside"] == ["pane": .null, "placement": "new_column"])
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
        // `file.open` says where it opened as the base does: `caller` with the pane its run was aimed at.
        #expect(reply["placement"] == "caller")
        #expect(reply["pane_id"] == "pane-agent")

        snapshot = Self.snapshot(own: Self.chat("tab-agent", session: "agent-1"), right: [Self.pane("pane-web", [Self.browser("tab-web")])])
        let (withColumn, columnExecutor) = install(snapshot)
        let beside = try await withColumn.handle(ControlRequest(id: "1", method: "file.open", params: [
            "path": "/tmp/site/index.html", "caller": ["agent_session": "agent-1"],
        ])).get()
        #expect(columnExecutor.all.first?.target == Self.paneTarget("pane-web"))
        #expect(columnExecutor.all.first?.besideCaller == true)
        #expect(beside["placement"] == "caller")
        #expect(beside["pane_id"] == "pane-web")
    }

    @Test func aFileFromATerminalFollowsTheSameRule() async throws {
        let (router, executor) = install(Self.snapshot())
        let agent = try await router.handle(ControlRequest(id: "1", method: "file.open", params: ["path": "/tmp/a.md", "terminal_id": "term-agent"])).get()
        #expect(executor.all.first?.target == Self.paneTarget("pane-agent"))
        #expect(executor.all.first?.newColumnBeside == true)
        #expect(agent["placement"] == "caller")
        #expect(agent["pane_id"] == "pane-agent")

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
        #expect(refused.failure?.message.contains("target tab:") == true, "it says what to pass: \(String(describing: refused.failure?.message))")
        #expect(refused.failure?.message.contains("tab-agent") != true, "and never offers the agent its own tab")
        #expect(executor.all.isEmpty, "an agent's close with no target closed something")

        let shell = try await run("closeTab", Self.snapshot(own: Self.terminal("tab-agent", "term-agent", agent: nil)))
        #expect(shell.target == Self.tabTarget("tab-agent"), "never the person's focused tab: \(String(describing: shell.target))")
    }

    /// The refusal comes before anything is aimed: a destructive browser action never reaches the nearest
    /// browser (the person's tab), and an action on a screen or a tab group never reaches the focused one.
    @Test(arguments: ["browser.pageInfo.deleteSiteData", "screen.closeOthers", "tabGroup.close"])
    func anAgentsDestructiveRunWithNoTargetIsRefusedBeforeItIsAimed(action: String) async throws {
        // The agent's workspace holds a browser: the nearest one, which a browser action would be aimed at.
        let snapshot = Self.snapshot(right: [Self.pane("pane-web", [Self.browser("tab-web")])], shown: true)
        let (router, executor) = install(snapshot)
        let refused = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": .string(action), "args": ["confirm": true], "caller": Self.agent,
        ]))
        #expect(refused.failure?.code == "target_required", "\(action): \(String(describing: refused))")
        #expect(refused.failure?.message.contains("tab-agent") != true, "the refusal never offers the agent its own tab")
        #expect(executor.all.isEmpty, "\(action) ran")
        // An agent session no tab shows is refused the same way.
        let unplaced = await router.handle(ControlRequest(id: "2", method: "action.run", params: [
            "action": .string(action), "args": ["confirm": true], "caller": ["agent_session": "gone"],
        ]))
        #expect(unplaced.failure?.code == "target_required")
        #expect(executor.all.isEmpty)
    }

    /// An action that names its object by its own argument is not refused, and is never aimed at the caller's own
    /// tab or workspace: `cmux cloud archive-session --session S` archives S, and with no `--session` the refusal
    /// says what to pass and does not offer the agent's own tab (that target archives the agent's own session).
    @Test func aClosingRunNamedByItsOwnArgumentRunsOnThatObject() async throws {
        let (router, executor) = install(Self.snapshot())
        let refused = await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "cloud.team.archive", "caller": Self.agent]))
        #expect(refused.failure?.code == "target_required")
        #expect(refused.failure?.message.contains("--session") == true, "\(String(describing: refused.failure?.message))")
        #expect(refused.failure?.message.contains("tab-agent") != true)
        #expect(refused.failure?.data?["arguments"] == ["session"])
        #expect(executor.all.isEmpty)
        // An empty or blank `--session` names nothing: it is refused as no `--session` is (review of 4fb5810d35c:
        // the handler read it as "no session" and archived the agent's own).
        for blank in ["", "  "] {
            let empty = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "cloud.team.archive", "args": ["session": .string(blank)], "caller": Self.agent,
            ]))
            #expect(empty.failure?.code == "target_required", "'\(blank)': \(String(describing: empty))")
            #expect(executor.all.isEmpty, "'\(blank)' ran")
        }

        let archived = try await run("cloud.team.archive", Self.snapshot(), args: ["session": "sess-9"])
        #expect(archived.target == nil, "not also aimed at the agent's own workspace: \(String(describing: archived.target))")
        #expect(archived.arguments["session"] == .string("sess-9"))
        let removed = try await run("bookmark.remove", Self.snapshot(), args: ["bookmark": "Docs"])
        #expect(removed.target == nil)
        #expect(removed.arguments["bookmark"] == .string("Docs"))
    }

    /// Close All Workspaces and Close Window take no target: unnamed they act on the window the person has in
    /// front. An agent must name the window, or cannot run the action at all; a person's shell is not refused.
    @Test func anAgentNeverClosesThePersonsFrontWindow() async throws {
        let (router, executor) = install(Self.snapshot())
        let refused = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "workspace.closeAll", "args": ["confirm": true], "caller": Self.agent,
        ]))
        #expect(refused.failure?.code == "target_required")
        #expect(refused.failure?.message.contains("--window") == true, "\(String(describing: refused.failure?.message))")
        let unnameable = await router.handle(ControlRequest(id: "2", method: "action.run", params: ["action": "closeWindow", "caller": Self.agent]))
        #expect(unnameable.failure?.code == "person_required")
        #expect(executor.all.isEmpty, "an agent closed the person's front window")

        let named = try await run("workspace.closeAll", Self.snapshot(), args: ["confirm": true, "window": "window:win-1"])
        #expect(named.target == nil)
        #expect(named.arguments["window"] == .target(ControlTargetRef(kind: "window", id: "win-1")))
        let shell = Self.snapshot(own: Self.terminal("tab-agent", "term-agent", agent: nil))
        #expect(try await run("workspace.closeAll", shell, args: ["confirm": true]).actionID == "workspace.closeAll")
        #expect(try await run("closeWindow", shell).target == nil)
    }

    /// A screen is a place a caller has of its own.
    @Test func aScreenRunUsesTheCallersOwnScreen() async throws {
        #expect(try await run("screen.rename", Self.snapshot()).target == ControlTargetRef(kind: "screen", id: "screen-agent"))
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

    // MARK: The base's caller rule (2026-11-18) is the same rule

    /// An agent whose chat no tab shows stands in the workspace its session runs in (`caller.workspace`): what it
    /// opens is placed there and a workspace run is that workspace; it has no tab or pane of its own for the rest.
    @Test func anAgentWithNoTabStandsInItsSessionsWorkspace() async throws {
        let closed: JSONValue = ["agent_session": "agent-closed", "workspace": "WS-AGENT"]
        let opened = try await run("openBrowser", Self.snapshot(), caller: closed, args: ["url": "https://example.com"])
        #expect(opened.target == Self.tabTarget("tab-agent"), "in its session's workspace: \(String(describing: opened.target))")
        #expect(opened.besideCaller)
        #expect(try await run("renameWorkspace", Self.snapshot(), caller: closed).target == ControlTargetRef(kind: "workspace", id: "ws-agent"))
        let (router, executor) = install(Self.snapshot())
        let refused = await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "renameTab", "caller": closed]))
        #expect(refused.failure?.code == "caller_unavailable", "the tab there is not its own")
        #expect(executor.all.isEmpty)
    }

    /// A Chief turn acts for the person across the app: only what it opens is placed (beside the Home chat).
    @Test func aChiefTurnsFileOpensBesideTheHomeChatAndItsOtherRunsAreUnchanged() async throws {
        var snapshot = HomeChatCallerTests.snapshot()
        snapshot.catalog = Self.catalog()
        let (router, executor) = install(snapshot)
        let reply = try await router.handle(ControlRequest(id: "1", method: "file.open", params: [
            "path": "/tmp/note.md", "caller": ["agent_session": "turn-on-a-vm", "home_chat": true],
        ])).get()
        #expect(executor.all.first?.target == Self.paneTarget("pane-right"), "\(String(describing: executor.all.first?.target))")
        #expect(executor.all.first?.besideCaller == true)
        #expect(reply["placement"] == "caller")
        #expect(reply["pane_id"] == "pane-right")
        #expect(try await run("splitRight", snapshot, caller: ["home_chat": true]).target == nil)
        #expect(try await run("closeTab", snapshot, caller: ["home_chat": true]).target == nil)
    }

    /// The CLI's `browser open` names the terminal's own tab: while a window shows it the app sends that browser
    /// where a Cmd-click's goes (TabLifecycle), and the run says which panes beside the caller are another
    /// agent's, so it is never one.
    @Test func aBrowserAimedAtTheCallersOwnTabStillKnowsTheOtherAgentsPanes() async throws {
        let other = Self.pane("pane-other", [Self.terminal("tab-other", "term-other", agent: "codex")])
        for own in [Self.terminal("tab-agent", "term-agent", agent: "claude"), Self.terminal("tab-agent", "term-agent", agent: nil)] {
            let (router, executor) = install(Self.snapshot(own: own, right: [other], shown: true))
            _ = try await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "openBrowser", "target": "tab:tab-agent", "caller": Self.agent,
            ])).get()
            let request = try #require(executor.all.first)
            #expect(request.target == Self.tabTarget("tab-agent"))
            #expect(!request.besideCaller, "the app's Cmd-click rule decides")
            #expect(request.besideAgentHomes == ["pane-other"])
        }
        // A plain shell's own run with no target carries them too.
        let shell = Self.snapshot(own: Self.terminal("tab-agent", "term-agent", agent: nil), right: [other], shown: true)
        #expect(try await run("openBrowser", shell).besideAgentHomes == ["pane-other"])
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

@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// #26648: an agent told to use the cmux browser drives the browser nearest
/// it (its own workspace, then its sidebar group, then its window), never the
/// person's focused browser in another window. Two windows: the person works
/// in window A, whose focused tab is a browser; the agent's terminal is in
/// window B.
@Suite(.timeLimit(.minutes(1))) struct BrowserCallerTargetTests {
    struct NoEngine: BrowserPageEngine {
        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue { [:] }
    }

    static let agent: JSONValue = ["terminal_id": "term-agent"]

    static func terminal(_ id: String, _ terminal: String) -> ControlTabInfo {
        ControlTabInfo(id: id, surface: id, kind: "terminal", title: "zsh", terminalID: terminal)
    }

    static func browser(_ id: String) -> ControlTabInfo {
        ControlTabInfo(id: id, surface: id, kind: "browser", title: id, url: "https://\(id).example/")
    }

    static func workspace(_ id: String, group: String? = nil, _ panes: [ControlPaneInfo]) -> ControlWorkspaceInfo {
        ControlWorkspaceInfo(id: id, handle: id, name: id, groupID: group, screens: [ControlScreenInfo(id: "screen-" + id, handle: "s" + id, panes: panes)])
    }

    static func pane(_ id: String, column: Int, _ tabs: [ControlTabInfo], selected: String? = nil) -> ControlPaneInfo {
        var pane = ControlPaneInfo(id: id, handle: id, selectedTabID: selected ?? tabs.first?.id, tabs: tabs)
        pane.column = column
        return pane
    }

    /// Window A (key, focused): ws-front, its browser focused. Window B: in sidebar order
    /// ws-near (browser, same group as the agent), ws-agent (the agent's terminal, `ownBrowser`
    /// beside it when given), ws-far (browser, no group).
    static func snapshot(ownBrowser: Bool = true, neighbors: Bool = true) -> ControlSnapshot {
        var snapshot = ControlSnapshot.sample()
        snapshot.catalog = ControlCatalog(actions: [
            ControlActionInfo(id: "browserReload", title: "Reload Page", category: "browser", categoryTitle: "Browser",
                              cliName: "browser reload-page", symbol: "arrow.clockwise", keywords: [], shortcut: nil, shortcutConfig: nil,
                              arguments: [], targets: ["pane"], requiresMask: 1 << 1, requires: ["browserFocused"],
                              isBound: true, isDebugOnly: false, mainMenu: nil),
        ], contextMask: 1 << 1, targetKinds: ["pane", "tab"], debugActionsAvailable: false)
        let front = workspace("ws-front", [pane("pane-front", column: 0, [browser("tab-front")])])
        var agentPanes = [pane("pane-agent", column: 0, [terminal("tab-agent", "term-agent")])]
        if ownBrowser {
            // The column right of the terminal shows a terminal; its browser tab is not selected.
            agentPanes.append(pane("pane-beside", column: 1, [browser("tab-own"), terminal("tab-shell", "term-shell")], selected: "tab-shell"))
        }
        let agent = workspace("ws-agent", group: "group-1", agentPanes)
        var workspaces = [front, agent]
        var order = ["ws-agent"]
        if neighbors {
            workspaces += [workspace("ws-near", group: "group-1", [pane("pane-near", column: 0, [browser("tab-near")])]),
                           workspace("ws-far", [pane("pane-far", column: 0, [browser("tab-far")])])]
            order = ["ws-far", "ws-near", "ws-agent"]
        }
        snapshot.topology.workspaces = workspaces
        snapshot.topology.windows = [
            ControlWindowInfo(id: "win-a", workspaceID: "ws-front", workspaceIDs: ["ws-front"], isKey: true, isVisible: true, focusedPaneID: "pane-front"),
            ControlWindowInfo(id: "win-b", workspaceID: "ws-agent", workspaceIDs: order, isKey: false, isVisible: true, focusedPaneID: "pane-agent"),
        ]
        snapshot.topology.focus = ControlFocus(windowID: "win-a", workspaceID: "ws-front", paneID: "pane-front", tabID: "tab-front")
        return snapshot
    }

    func install(_ snapshot: ControlSnapshot) -> (ControlRouter, RecordingExecutor) {
        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        BrowserPageService(engine: NoEngine()).install(on: router)
        router.snapshots.publish { $0 = snapshot }
        return (router, executor)
    }

    func state(_ router: ControlRouter, caller: JSONValue?) async -> Result<JSONValue, ControlError> {
        var params: [String: JSONValue] = [:]
        if let caller { params["caller"] = caller }
        return await router.handle(ControlRequest(method: "browser.page.state", params: params))
    }

    @Test func anAgentDrivesTheBrowserInItsOwnWorkspaceNotTheFocusedOneInAnotherWindow() async throws {
        let (router, _) = install(Self.snapshot())
        let result = try await state(router, caller: Self.agent).get()
        #expect(result["tab"] == "tab-own")
    }

    @Test func withoutOneInItsWorkspaceItTakesTheSameGroupThenTheWindowNeverTheOtherWindow() async throws {
        let (router, _) = install(Self.snapshot(ownBrowser: false))
        #expect(try await state(router, caller: Self.agent).get()["tab"] == "tab-near")

        var ungrouped = Self.snapshot(ownBrowser: false)
        ungrouped.topology.workspaces.removeAll { $0.id == "ws-near" }
        let (window, _) = install(ungrouped)
        #expect(try await state(window, caller: Self.agent).get()["tab"] == "tab-far")

        let (alone, _) = install(Self.snapshot(ownBrowser: false, neighbors: false))
        let refused = await state(alone, caller: Self.agent)
        guard case .failure(let error) = refused else { Issue.record("drove \(refused)"); return }
        #expect(error.code == "not_found")
        #expect(error.data?["workspace"] == "ws-agent")
    }

    @Test func aCallWithNoCallerOrAnUnknownOneKeepsTheFocusedTab() async throws {
        let (router, _) = install(Self.snapshot())
        #expect(try await state(router, caller: nil).get()["tab"] == "tab-front")
        #expect(try await state(router, caller: ["terminal_id": "term-gone"]).get()["tab"] == "tab-front")
        // A named tab is always that tab.
        let named = try await router.handle(ControlRequest(method: "browser.page.state",
                                                           params: ["tab": "tab-front", "caller": Self.agent])).get()
        #expect(named["tab"] == "tab-front")
    }

    @Test func identifyAndTheTabListReportTheCallersBrowser() async throws {
        let (router, _) = install(Self.snapshot())
        let identity = try await router.handle(ControlRequest(method: "system.identify", params: ["caller": Self.agent])).get()
        #expect(identity["browser"]?["tab"] == "tab-own")
        #expect(identity["browser"]?["pane"] == "pane-beside")
        #expect(identity["browser"]?["session"] == .null)
        let tabs = try await router.handle(ControlRequest(method: "browser.page.tabs", params: ["caller": Self.agent])).get()
        guard case .array(let listed)? = tabs["tabs"] else { Issue.record("no tabs: \(tabs)"); return }
        #expect(listed.compactMap { $0["id"]?.stringValue } == ["tab-own"])
    }

    /// `cmux browser reload-page` (and the MCP action tool) from the agent reloads its
    /// browser: the pane that shows it, never the focused pane in window A. A browser its
    /// pane does not show is refused (the pane-only action would reach the pane's terminal).
    @Test func aBrowserActionWithoutATargetRunsOnTheCallersBrowser() async throws {
        var shown = Self.snapshot()
        shown.topology.workspaces[1].screens[0].panes[1].selectedTabID = "tab-own"
        let (router, executor) = install(shown)
        _ = try await router.handle(ControlRequest(method: "action.run", params: ["action": "browserReload", "caller": Self.agent])).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "pane", id: "pane-beside"))

        let (hidden, hiddenExecutor) = install(Self.snapshot())
        let unshown = await hidden.handle(ControlRequest(method: "action.run", params: ["action": "browserReload", "caller": Self.agent]))
        guard case .failure(let notShown) = unshown else { Issue.record("ran \(unshown)"); return }
        #expect(notShown.code == "unavailable")
        #expect(notShown.data?["tab"] == "tab-own")
        #expect(hiddenExecutor.last == nil)

        let (alone, _) = install(Self.snapshot(ownBrowser: false, neighbors: false))
        let refused = await alone.handle(ControlRequest(method: "action.run", params: ["action": "browserReload", "caller": Self.agent]))
        guard case .failure(let error) = refused else { Issue.record("ran \(refused)"); return }
        #expect(error.code == "not_found")
    }

    /// Page verbs, actions and `identify` pick the same browser: one in another session (a
    /// remote workspace of the group) is passed over for the caller's own session's, since the
    /// CLI and MCP address the daemon of the caller's session.
    @Test func everyPathPassesOverABrowserInAnotherSession() async throws {
        var snapshot = Self.snapshot(ownBrowser: false)
        let near = try #require(snapshot.topology.workspaces.firstIndex { $0.id == "ws-near" })
        snapshot.topology.workspaces[near].sessionID = "session-remote"
        let (router, _) = install(snapshot)
        #expect(try await state(router, caller: Self.agent).get()["tab"] == "tab-far")
        let identity = try await router.handle(ControlRequest(method: "system.identify", params: ["caller": Self.agent])).get()
        #expect(identity["browser"]?["tab"] == "tab-far")
    }

    /// `cmux browser page new-tab URL` with no browser near the caller opens its first one, not a
    /// refusal: a terminal's in its own pane behind the terminal, an agent's beside its chat
    /// (`openBrowser` with the caller, placed by `placeBesideCaller`).
    @Test func aNewTabWithNoBrowserNearOpensOneForTheCaller() async throws {
        var snapshot = Self.snapshot(ownBrowser: false, neighbors: false)
        let openBrowser = ControlActionInfo(id: "openBrowser", title: "New Browser Tab", category: "tab", categoryTitle: "Tab",
                                            cliName: "tab new-browser", symbol: "globe", keywords: [], shortcut: nil, shortcutConfig: nil,
                                            arguments: [], targets: ["tab"], requiresMask: 0, requires: [],
                                            isBound: true, isDebugOnly: false, mainMenu: nil)
        snapshot.catalog = ControlCatalog(actions: snapshot.catalog.actions + [openBrowser], contextMask: 1 << 1,
                                          targetKinds: ["pane", "tab"], debugActionsAvailable: false)
        let agentPane = snapshot.topology.workspaces[1].screens[0].panes[0]
        var chat = ControlTabInfo(id: "tab-chat", surface: "tab-chat", kind: "agent", title: "Claude")
        chat.agentSessionID = "agent-1"
        snapshot.topology.workspaces[1].screens[0].panes = [agentPane, Self.pane("pane-chat", column: 1, [chat])]
        let (router, executor) = install(snapshot)

        _ = try await router.handle(ControlRequest(method: "browser.page.new_tab", params: ["caller": Self.agent, "wait": false])).get()
        #expect(executor.last?.actionID == "openBrowser")
        #expect(executor.last?.target == ControlTargetRef(kind: "tab", id: "tab-agent"))
        #expect(executor.last?.background == true)

        _ = try await router.handle(ControlRequest(method: "browser.page.new_tab",
                                                   params: ["caller": ["agent_session": "agent-1"], "wait": false])).get()
        #expect(executor.last?.actionID == "openBrowser")
        #expect(executor.last?.callerAgentSession == "agent-1")
        #expect(executor.last?.besideCaller == true)
        // The chat's column is the rightmost: the browser opens in a new column beside it.
        #expect(executor.last?.target == ControlTargetRef(kind: "tab", id: "tab-chat"))
        #expect(executor.last?.newColumnBeside == true)
    }
}

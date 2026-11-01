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

    @Test(arguments: [false, true]) func focusPreferenceBelongsToItsWorkspace(inCallerWorkspace: Bool) async throws {
        var snapshot = Self.snapshot()
        snapshot.topology.workspaces[0].sessionID = "session-remote"
        snapshot.topology.workspaces[1].screens[0].panes[1].selectedTabID = "tab-own"
        snapshot.topology.workspaces[1].screens[0].panes.append(Self.pane("pane-farther", column: 3, [Self.browser("tab-front")]))
        if inCallerWorkspace {
            snapshot.topology.focus = ControlFocus(windowID: "win-b", workspaceID: "ws-agent", paneID: "pane-farther", tabID: "tab-front")
        }
        let (router, executor) = install(snapshot)
        #expect(try await state(router, caller: Self.agent).get()["tab"] == .string(inCallerWorkspace ? "tab-front" : "tab-own"))
        _ = try await router.handle(ControlRequest(method: "action.run", params: ["action": "browserReload", "caller": Self.agent])).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "pane", id: inCallerWorkspace ? "pane-farther" : "pane-beside"))
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

    @Test func noCallerUsesTheFocusedTabButAnExplicitTabAlwaysWins() async throws {
        let (router, _) = install(Self.snapshot())
        #expect(try await state(router, caller: nil).get()["tab"] == "tab-front")
        // An explicit tab overrides the caller, even if that caller has since closed.
        let named = try await router.handle(ControlRequest(method: "browser.page.state",
                                                           params: ["tab": "tab-front", "caller": ["terminal_id": "term-gone"]])).get()
        #expect(named["tab"] == "tab-front")
    }

    @Test func staleCallerNeverReadsOrNavigatesThePersonsFocusedBrowser() async throws {
        let (router, executor) = install(Self.snapshot())
        let stale: JSONValue = ["terminal_id": "term-gone"]
        #expect(await state(router, caller: stale).failure?.code == "caller_unavailable")
        let navigate = await router.handle(ControlRequest(method: "browser.page.navigate",
            params: ["url": "https://example.test/", "caller": stale]))
        #expect(navigate.failure?.code == "caller_unavailable")
        #expect(executor.last == nil)
    }

    @Test func staleCallerNeverRunsBrowserActionsOrListsAnotherWorkspace() async throws {
        let (router, executor) = install(Self.snapshot())
        let stale: JSONValue = ["terminal_id": "term-gone"]
        let action = await router.handle(ControlRequest(method: "action.run",
            params: ["action": "browserReload", "caller": stale]))
        #expect(action.failure?.code == "caller_unavailable")
        #expect(executor.last == nil)
        let tabs = await router.handle(ControlRequest(method: "browser.page.tabs", params: ["caller": stale]))
        #expect(tabs.failure?.code == "caller_unavailable")
        // A deliberately unscoped list still works without relying on the focused workspace.
        let all = try await router.handle(ControlRequest(method: "browser.page.tabs",
            params: ["caller": stale, "all": true])).get()
        #expect((all["tabs"]?.arrayValue ?? []).count > 1)
    }

    @Test func emptyOrInvalidCallerCannotSilentlyBecomeFocusedTab() async throws {
        let (router, _) = install(Self.snapshot())
        for caller: JSONValue in [.object([:]), ["terminal_id": ""], ["home_chat": false]] {
            #expect(await state(router, caller: caller).failure?.code == "invalid_params")
        }
        #expect(await state(router, caller: ["terminal_id": 1]).failure?.code == "invalid_params")
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

    @Test(arguments: ["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "inspectBrowserElement", "browser.editSource"])
    func browserActionsWithoutFocusRequirementsUseTheCallersBrowser(actionID: String) async throws {
        var snapshot = Self.snapshot()
        snapshot.topology.workspaces[1].screens[0].panes[1].selectedTabID = "tab-own"
        // Inspectors and Edit Source have no browserFocused requirement in the catalog.
        let targetKind = actionID == "browser.editSource" ? "tab" : "pane"
        snapshot.catalog = ControlCatalog(actions: [
            ControlActionInfo(id: actionID, title: actionID, category: "browser", categoryTitle: "Browser",
                              cliName: actionID, symbol: "hammer", keywords: [], shortcut: nil, shortcutConfig: nil,
                              arguments: [], targets: [targetKind], requiresMask: 0, requires: [],
                              isBound: true, isDebugOnly: false, mainMenu: nil),
        ], contextMask: 1 << 1, targetKinds: ["pane", "tab"], debugActionsAvailable: false)
        let (router, executor) = install(snapshot)
        _ = try await router.handle(ControlRequest(method: "action.run", params: ["action": .string(actionID), "caller": Self.agent])).get()
        #expect(executor.last?.target == ControlTargetRef(kind: targetKind, id: targetKind == "tab" ? "tab-own" : "pane-beside"))

        var alone = Self.snapshot(ownBrowser: false, neighbors: false)
        alone.catalog = snapshot.catalog
        let (refusing, refusingExecutor) = install(alone)
        let refused = await refusing.handle(ControlRequest(method: "action.run", params: ["action": .string(actionID), "caller": Self.agent]))
        guard case .failure(let error) = refused else { Issue.record("ran \(refused)"); return }
        #expect(error.code == "not_found")
        #expect(refusingExecutor.last == nil)
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

    @Test(arguments: [false, true]) func aMirroredBrowserStaysInTheCallersSession(duplicateID: Bool) async throws {
        var snapshot = Self.snapshot(ownBrowser: false)
        let expectedTab = duplicateID ? "tab-mirror" : "tab-near"
        let near = try #require(snapshot.topology.workspaces.firstIndex { $0.id == "ws-near" })
        snapshot.topology.workspaces[near].screens[0].panes[0].tabs = [Self.browser(expectedTab)]
        snapshot.topology.workspaces[near].screens[0].panes[0].selectedTabID = expectedTab
        let agent = try #require(snapshot.topology.workspaces.firstIndex { $0.id == "ws-agent" })
        var mirror = Self.pane("pane-mirror", column: 1, [], selected: "tab-mirror")
        mirror.mirroredTabIDs = ["tab-mirror"]
        snapshot.topology.workspaces[agent].screens[0].panes.append(mirror)
        var remoteTab = Self.browser("tab-mirror")
        remoteTab.url = "https://remote.example/"
        var remote = Self.workspace("ws-remote", [Self.pane("pane-remote", column: 0, [remoteTab])])
        remote.sessionID = "session-remote"
        // Session-local IDs may repeat. The remote copy appears first in topology order.
        snapshot.topology.workspaces.insert(remote, at: 0)
        let (router, executor) = install(snapshot)

        let page = try await state(router, caller: Self.agent).get()
        #expect(page["tab"] == .string(expectedTab))
        #expect(page["url"] == .string("https://\(expectedTab).example/"))
        let identity = try await router.handle(ControlRequest(method: "system.identify", params: ["caller": Self.agent])).get()
        #expect(identity["browser"]?["workspace"] == "ws-near")
        #expect(identity["browser"]?["session"] == .null)
        _ = try await router.handle(ControlRequest(method: "action.run", params: ["action": "browserReload", "caller": Self.agent])).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "pane", id: duplicateID ? "pane-mirror" : "pane-near"))
    }

    @Test func anAmbiguousMirroredBrowserDoesNotChooseTheFirstMatchingTab() async throws {
        var snapshot = Self.snapshot(neighbors: false)
        var mirror = Self.pane("pane-mirror", column: 1, [], selected: "tab-duplicate")
        mirror.mirroredTabIDs = ["tab-duplicate"]
        snapshot.topology.workspaces[1].screens[0].panes.insert(mirror, at: 1)
        for id in ["ws-duplicate-a", "ws-duplicate-b"] {
            snapshot.topology.workspaces.append(Self.workspace(id, [Self.pane("pane-" + id, column: 0, [Self.browser("tab-duplicate")])]))
        }
        let (router, _) = install(snapshot)
        #expect(try await state(router, caller: Self.agent).get()["tab"] == "tab-own")
        let identity = try await router.handle(ControlRequest(method: "system.identify", params: ["caller": Self.agent])).get()
        #expect(identity["browser"]?["workspace"] == "ws-agent")
    }

    @Test(arguments: ["elsewhere", "own", "mirror"])
    func anActionWithNoTargetRequiresTheSameFocusedBrowser(focus: String) async throws {
        var snapshot = Self.snapshot(ownBrowser: false, neighbors: false)
        snapshot.catalog = ControlCatalog(actions: [
            ControlActionInfo(id: "browserShowHistory", title: "Show Browser History", category: "browser", categoryTitle: "Browser",
                              cliName: "browser show-history", symbol: "clock", keywords: [], shortcut: nil, shortcutConfig: nil,
                              arguments: [], targets: [], requiresMask: 1 << 1, requires: ["browserFocused"],
                              isBound: true, isDebugOnly: false, mainMenu: nil),
        ], contextMask: 1 << 1, targetKinds: ["tab", "pane"], debugActionsAvailable: false)
        snapshot.topology.workspaces[0].sessionID = "session-remote"
        var pane = Self.pane("pane-local", column: 1, [Self.browser("tab-front")])
        if focus == "mirror" {
            pane.tabs = []
            pane.selectedTabID = "tab-front"
            pane.mirroredTabIDs = ["tab-front"]
            snapshot.topology.workspaces.append(Self.workspace("ws-owner", [Self.pane("pane-owner", column: 0, [Self.browser("tab-front")])]))
        }
        snapshot.topology.workspaces[1].screens[0].panes.append(pane)
        if focus != "elsewhere" {
            snapshot.topology.focus = ControlFocus(windowID: "win-b", workspaceID: "ws-agent", paneID: "pane-local", tabID: "tab-front")
        }
        let (router, executor) = install(snapshot)
        let result = await router.handle(ControlRequest(method: "action.run", params: ["action": "browserShowHistory", "caller": Self.agent]))
        if focus == "elsewhere" {
            #expect(result.failure?.code == "unavailable")
            #expect(executor.last == nil)
        } else {
            #expect(try result.get()["ran"] == true)
            #expect(executor.last?.actionID == "browserShowHistory")
        }
    }

    @Test(arguments: [false, true]) func creatingTheFirstBrowserCanBeRetriedAfterTopologyChanges(agentChat: Bool) async throws {
        var snapshot = Self.snapshot(ownBrowser: false, neighbors: false)
        snapshot.catalog = ControlCatalog(actions: [
            BrowserPageTabsTests.action("openBrowser", [ControlArgumentInfo(name: "url", title: "URL", kind: .string, isRequired: false)]),
        ], targetKinds: ["tab", "pane"], debugActionsAvailable: false)
        if agentChat {
            var chat = ControlTabInfo(id: "tab-chat", surface: "tab-chat", kind: "agent", title: "Agent")
            chat.agentSessionID = "agent-1"
            snapshot.topology.workspaces[1].screens[0].panes.append(Self.pane("pane-chat", column: 1, [chat]))
        }
        let caller: JSONValue = agentChat ? ["agent_session": "agent-1"] : Self.agent
        let (router, executor) = install(snapshot)
        let request = ControlRequest(method: "browser.page.new_tab", params: [
            "caller": caller, "url": "https://example.com/", "idempotency_key": "first-browser",
        ])
        let first = try await router.handle(request).get()
        router.snapshots.publish {
            $0.topology.workspaces[1].screens[0].panes.append(Self.pane("pane-created", column: 2, [Self.browser("tab-created")]))
        }
        let replay = try await router.handle(request).get()
        #expect(replay["replayed"] == true)
        #expect(replay["created"] == first["created"])
        #expect(replay["tab"] == first["tab"])
        #expect(executor.requests.withLock { $0.count } == 1)

        var changed = request
        changed.params["url"] = "https://different.example/"
        #expect(await router.handle(changed).failure?.code == "idempotency_conflict")
        changed = request
        changed.params["caller"] = ["terminal_id": "another-terminal"]
        #expect(await router.handle(changed).failure?.code == "idempotency_conflict")

        // Replaying a finished create does not depend on the caller or its browser still existing.
        router.snapshots.publish { $0.topology.workspaces.removeAll() }
        let afterClose = try await router.handle(request).get()
        #expect(afterClose["replayed"] == true)
        #expect(afterClose["created"] == first["created"])
        #expect(executor.requests.withLock { $0.count } == 1)
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

@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization
import Testing

/// Runs `openBrowser` like the App: the new tab is a daemon command in the
/// run's scope (ticket, created surface, barrier), and the next snapshot
/// shows it in the target pane. Every other action runs with no command.
final class OpenBrowserExecutor: ControlActionExecutor {
    let requests = Mutex<[ControlActionRequest]>([])
    let outcome: ControlActionOutcome
    let router = Mutex<ControlRouter?>(nil)

    init(outcome: ControlActionOutcome = .ran) {
        self.outcome = outcome
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { performActionTracked(request).outcome }

    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        requests.withLock { $0.append(request) }
        guard outcome == .ran, request.actionID == "openBrowser" else { return ControlActionRun(outcome: outcome) }
        let router = router.withLock { $0 }
        // The pane the tab goes to: the target tab's, else the focused pane.
        let topology = router?.snapshots.current.topology
        let paneID = request.target.flatMap { topology?.tab(id: $0.id)?.pane.id } ?? topology?.focus.paneID ?? "pane-1"
        Task { @MainActor in
            let scope = ControlCommandScope.current
            let ticket = scope?.begin()
            router?.snapshots.publish { snapshot in
                let tab = ControlTabInfo(id: "tab-new", surface: "21", kind: "browser", title: "Example")
                for w in snapshot.topology.workspaces.indices {
                    for s in snapshot.topology.workspaces[w].screens.indices {
                        for p in snapshot.topology.workspaces[w].screens[s].panes.indices
                        where snapshot.topology.workspaces[w].screens[s].panes[p].id == paneID {
                            snapshot.topology.workspaces[w].screens[s].panes[p].tabs.append(tab)
                        }
                    }
                }
                snapshot.topology.daemonSequence = 9
            }
            scope?.noteCreated([ControlCreatedObject(.tab, "21")])
            scope?.noteBarrier(9, machine: ControlCommandScope.localMachine)
            scope?.end(ticket, failure: nil)
        }
        return ControlActionRun(outcome: .ran)
    }

    var all: [ControlActionRequest] { requests.withLock { $0 } }
}

/// `browser.open_split` (`cmux open <url>`, `cmux open -`, cmux-chat) opens
/// one browser tab through `openBrowser`, the path `cmux browser open` takes,
/// and reports it; it never switches the view unless asked (cx-i2iu).
@Suite(.timeLimit(.minutes(1))) struct BrowserOpenSplitTests {
    static func catalog() -> ControlCatalog {
        let url = ControlArgumentInfo(name: "url", title: "URL", kind: .string, isRequired: false)
        func action(_ id: String, _ cli: String, _ arguments: [ControlArgumentInfo]) -> ControlActionInfo {
            ControlActionInfo(id: id, title: id, category: "tab", categoryTitle: "Tabs", cliName: cli, symbol: "globe", keywords: [],
                              shortcut: nil, shortcutConfig: nil, arguments: arguments, targets: ["tab"], requiresMask: 0, requires: [],
                              isBound: true, isDebugOnly: false, mainMenu: nil)
        }
        return ControlCatalog(actions: [action("openBrowser", "tab new-browser", [url]), action("tab.focus", "tab focus", [])],
                              contextMask: 0, aliases: [:],
                              targetKinds: ["tab", "tab-group", "pane", "column", "screen", "workspace", "workspace-group", "window"],
                              debugActionsAvailable: true)
    }

    /// ws-1 is shown (pane-1 focused, the caller's terminal term-a in tab-1).
    /// ws-2 (`ws_bbb`) is in the background; its screen's default pane is pane-3.
    static func snapshot(showsPage: Bool = false) -> ControlSnapshot {
        var snapshot = ControlSnapshot()
        snapshot.catalog = catalog()
        var topology = ControlTopology()
        topology.isLoaded = true
        topology.daemonState = "connected"
        let tab1 = ControlTabInfo(id: "tab-1", surface: "11", kind: "terminal", title: "zsh", terminalID: "term-a")
        let pane1 = ControlPaneInfo(id: "pane-1", handle: "5", selectedTabID: "tab-1", tabs: [tab1])
        var ws1 = ControlWorkspaceInfo(id: "ws-1", handle: "1", name: "Main", screens: [ControlScreenInfo(id: "screen-1", handle: "2", panes: [pane1])])
        ws1.resourceID = "ws_aaa"
        let pane2 = ControlPaneInfo(id: "pane-2", handle: "6", selectedTabID: "tab-2",
                                    tabs: [ControlTabInfo(id: "tab-2", surface: "12", kind: "terminal", title: "zsh", terminalID: "term-b")])
        let pane3 = ControlPaneInfo(id: "pane-3", handle: "7", selectedTabID: "tab-3",
                                    tabs: [ControlTabInfo(id: "tab-3", surface: "13", kind: "terminal", title: "zsh", terminalID: "term-c")])
        var screen2 = ControlScreenInfo(id: "screen-2", handle: "3", panes: [pane2, pane3])
        screen2.defaultPaneID = "pane-3"
        var ws2 = ControlWorkspaceInfo(id: "ws-2", handle: "4", name: "Background", screens: [screen2])
        ws2.resourceID = "ws_bbb"
        topology.workspaces = [ws1, ws2]
        topology.windows = [ControlWindowInfo(id: "win-1", workspaceID: "ws-1", isKey: true, isVisible: true,
                                              focusedPaneID: showsPage ? nil : "pane-1")]
        topology.focus = ControlFocus(windowID: "win-1", workspaceID: "ws-1", paneID: showsPage ? nil : "pane-1",
                                      tabID: showsPage ? nil : "tab-1")
        snapshot.topology = topology
        return snapshot
    }

    func makeRouter(_ executor: OpenBrowserExecutor, showsPage: Bool = false) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = Self.snapshot(showsPage: showsPage) }
        executor.router.withLock { $0 = router }
        return router
    }

    func open(_ router: ControlRouter, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: "browser.open_split", params: params))
    }

    @Test func theMethodIsServed() {
        let router = makeRouter(OpenBrowserExecutor())
        #expect(router.methodNames.contains("browser.open_split"))
    }

    @Test func opensExactlyOneTabThroughOpenBrowserAndReportsIt() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        let reply = try await open(router, ["url": "https://example.com/a?b=1", "focus": false]).get()
        let runs = executor.all
        #expect(runs.count == 1, "one action run, no reveal: \(runs.map(\.actionID))")
        #expect(runs.first?.actionID == "openBrowser")
        #expect(runs.first?.arguments["url"] == .string("https://example.com/a?b=1"))
        #expect(runs.first?.target == nil, "no workspace, no caller terminal: the focused pane")
        #expect(runs.first?.focus == false)
        #expect(reply["tab_id"] == "tab-new")
        #expect(reply["created"] == ["tab-new"])
        #expect(reply["pane_id"] == "pane-1")
        #expect(reply["workspace_id"] == "ws_aaa")
        #expect(reply["placement"] == "focused_pane")
        #expect(reply["revealed"] == false)
    }

    @Test func aBackgroundWorkspaceGetsTheTabInItsDefaultPaneWithoutAViewChange() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        let reply = try await open(router, ["url": "https://example.com/", "workspace_id": "ws_bbb", "focus": false]).get()
        let runs = executor.all
        #expect(runs.map(\.actionID) == ["openBrowser"], "focus false runs no tab.focus")
        #expect(runs.first?.target == ControlTargetRef(kind: "tab", id: "tab-3"))
        #expect(runs.first?.focus == false, "the run may not change the view")
        #expect(reply["workspace_id"] == "ws_bbb")
        #expect(reply["pane_id"] == "pane-3")
        #expect(reply["placement"] == "workspace")
        #expect(router.snapshots.current.topology.focus.workspaceID == "ws-1")
    }

    @Test func anUnknownWorkspaceIsNotFoundAndRunsNothing() async {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        guard case .failure(let error) = await open(router, ["url": "https://example.com/", "workspace_id": "ws_nope"]) else {
            Issue.record("an unknown workspace opened a tab")
            return
        }
        #expect(error.code == "not_found")
        #expect(executor.all.isEmpty)
    }

    @Test func theCallersTerminalPaneGetsTheTab() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        let reply = try await open(router, ["url": "https://example.com/", "terminal_id": "term-b"]).get()
        #expect(executor.all.first?.target == ControlTargetRef(kind: "tab", id: "tab-2"))
        #expect(reply["placement"] == "caller_terminal")
        #expect(reply["pane_id"] == "pane-2")
        #expect(executor.all.count == 1)
    }

    @Test func aWindowShowingAPageOpensInItsWorkspaceAndShowsTheTab() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor, showsPage: true)
        let reply = try await open(router, ["url": "https://example.com/"]).get()
        let runs = executor.all
        #expect(runs.map(\.actionID) == ["openBrowser", "tab.focus"])
        #expect(runs.first?.target == ControlTargetRef(kind: "tab", id: "tab-1"))
        #expect(runs.last?.target == ControlTargetRef(kind: "tab", id: "tab-new"))
        #expect(runs.last?.focus == true)
        #expect(reply["placement"] == "window_workspace")
        #expect(reply["revealed"] == true)
    }

    /// cmux-lawrence-2 check: the window showed Home, whose workspace is the
    /// Home workspace drawn as the Home page, so a tab there was never seen.
    @Test func aWindowShowingTheHomeWorkspaceOpensInItsFirstOtherWorkspace() async throws {
        let executor = OpenBrowserExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { snapshot in
            snapshot = Self.snapshot(showsPage: true)
            snapshot.topology.workspaces[0].kind = "home"
            snapshot.topology.windows[0].workspaceIDs = ["ws-1", "ws-2"]
        }
        executor.router.withLock { $0 = router }
        let reply = try await open(router, ["url": "https://example.com/"]).get()
        #expect(executor.all.first?.target == ControlTargetRef(kind: "tab", id: "tab-3"), "ws-2's default pane")
        #expect(executor.all.last?.actionID == "tab.focus")
        #expect(reply["workspace_id"] == "ws_bbb")
        #expect(reply["placement"] == "window_workspace")
    }

    @Test func focusTrueLetsTheRunChangeTheViewAndShowsTheTab() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        let reply = try await open(router, ["url": "https://example.com/", "focus": true]).get()
        let runs = executor.all
        #expect(runs.map(\.actionID) == ["openBrowser", "tab.focus"])
        #expect(runs.first?.focus == true)
        #expect(reply["revealed"] == true)
    }

    /// cmux-chat (271491197ee3) runs `cmux open "http://127.0.0.1:<port>/o/<code>" >/dev/null`
    /// from its terminal: not a tty, so focus is false, and the CLI passes the caller's terminal.
    @Test func cmuxChatsOneTimeCodeURLOpensInTheCallersPaneAndIsNeverEchoed() async throws {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        // The App's sync barrier: the daemon has applied everything up to now.
        router.registerSyncBarrier { 0 }
        let url = "http://127.0.0.1:7739/o/Zx9k2LqP4w"
        // The exact params the CLI sends, `after: "sync"` (its read barrier) included.
        let reply = try await open(router, ["url": .string(url), "focus": false, "terminal_id": "term-a", "origin": "script",
                                            "after": "sync"]).get()
        #expect(executor.all.count == 1)
        #expect(executor.all.first?.arguments["url"] == .string(url))
        #expect(executor.all.first?.origin == "script")
        #expect(reply["tab_id"] == "tab-new")
        #expect(!reply.compactText.contains("Zx9k2LqP4w"), "the reply never carries the URL")
    }

    @Test func transparentBackgroundIsRefusedNotIgnored() async {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        guard case .failure(let error) = await open(router, ["url": "https://example.com/", "transparent_background": true]) else {
            Issue.record("transparent_background was ignored")
            return
        }
        #expect(error.code == "unsupported")
        #expect(executor.all.isEmpty)
        let opaque = await open(router, ["url": "https://example.com/", "transparent_background": false])
        #expect((try? opaque.get()) != nil, "false is what cmux-next does")
    }

    @Test func anUnknownParamIsRefused() async {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        guard case .failure(let error) = await open(router, ["url": "https://example.com/", "surface_id": "s"]) else {
            Issue.record("an unknown param was ignored")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(error.message.contains("surface_id"))
        #expect(executor.all.isEmpty)
    }

    @Test(arguments: ["", "example.com", "javascript:alert(1)", "file:///etc/passwd", "https://", "https://exa mple.com/?token=SECRET9"])
    func aURLThatIsNotAbsoluteHTTPIsRefusedWithoutEchoingIt(_ url: String) async {
        let executor = OpenBrowserExecutor()
        let router = makeRouter(executor)
        guard case .failure(let error) = await open(router, ["url": .string(url)]) else {
            Issue.record("\(url) opened")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(url.isEmpty || !error.message.contains(url))
        #expect(!error.message.contains("SECRET9"))
        #expect(executor.all.isEmpty)
    }

    @Test func aRefusedOpenFailsAndRevealsNothing() async {
        let executor = OpenBrowserExecutor(outcome: .refused("no browser engine"))
        let router = makeRouter(executor)
        guard case .failure = await open(router, ["url": "https://example.com/", "focus": true]) else {
            Issue.record("a refused open succeeded")
            return
        }
        #expect(executor.all.map(\.actionID) == ["openBrowser"])
    }
}

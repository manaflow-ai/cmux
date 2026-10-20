@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// `browser.page.right` (`cmux browser right <verb>`): the browser in the
/// column right of the Home chat is one target every Chief can name, local or
/// cloud. It reuses the agent's own tab there, else the shown browser tab,
/// else opens one in that column (never in the dock, never moving focus), and
/// one agent at a time drives a tab (plans/cmux-next/chief-browser-use-DESIGN.md).
@Suite(.timeLimit(.minutes(1))) struct BrowserPageRightTests {
    struct NoEngine: BrowserPageEngine {
        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue { [:] }
    }

    /// Records each run; `openBrowser` adds a browser tab to the pane the run
    /// names, as the app's handler does, so the method can find what it opened.
    final class OpeningExecutor: ControlActionExecutor {
        let requests = Mutex<[ControlActionRequest]>([])
        let router = Mutex<ControlRouter?>(nil)
        let opened = Mutex(0)

        @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
            requests.withLock { $0.append(request) }
            guard request.actionID == "openBrowser", let router = router.withLock({ $0 }) else { return .ran }
            let number = opened.withLock { value -> Int in
                value += 1
                return value
            }
            let url = request.arguments["url"]?.json.stringValue
            router.snapshots.publish { snapshot in
                for w in snapshot.topology.workspaces.indices {
                    for s in snapshot.topology.workspaces[w].screens.indices {
                        for p in snapshot.topology.workspaces[w].screens[s].panes.indices
                        where snapshot.topology.workspaces[w].screens[s].panes[p].tabs.contains(where: { $0.id == request.target?.id }) {
                            let tab = ControlTabInfo(id: "tab_new\(number)", surface: "9\(number)", kind: "browser", title: "New", url: url)
                            snapshot.topology.workspaces[w].screens[s].panes[p].tabs.append(tab)
                            snapshot.topology.workspaces[w].screens[s].panes[p].selectedTabID = tab.id
                        }
                    }
                }
            }
            return .ran
        }

        var last: ControlActionRequest? { requests.withLock { $0.last } }
        var count: Int { requests.withLock { $0.count } }
    }

    static let rightPane = "pane_right"
    static let dockPane = "pane_dock"

    /// Home: the chat dock (column 0, a left dock) and the column right of it
    /// with a Markdown page and the user's browser tab, which it shows.
    static func homeSnapshot(rightColumn: Bool = true) -> ControlSnapshot {
        var snapshot = ControlSnapshot.sample()
        snapshot.catalog = ControlCatalog(actions: [
            BrowserPageTabsTests.action("openBrowser", [ControlArgumentInfo(name: "url", title: "URL", kind: .string, isRequired: false)]),
        ], targetKinds: ["tab"], debugActionsAvailable: false)
        var chat = ControlTabInfo(id: "tab_chat", surface: "30", kind: "page", title: "Home")
        chat.page = "home-dock"
        var dock = ControlPaneInfo(id: dockPane, handle: "31", selectedTabID: "tab_chat", tabs: [chat])
        dock.column = 0
        dock.dock = "left"
        var markdown = ControlTabInfo(id: "tab_markdown", surface: "32", kind: "page", title: "Markdown")
        markdown.page = "markdown"
        let user = ControlTabInfo(id: "tab_user", surface: "33", kind: "browser", title: "Mail", url: "https://mail.example.com/")
        var right = ControlPaneInfo(id: rightPane, handle: "34", selectedTabID: "tab_user", tabs: [markdown, user])
        right.column = 1
        var home = ControlWorkspaceInfo(id: "home-key", handle: "35", name: "Home",
                                        screens: [ControlScreenInfo(id: "screen_home", handle: "36", panes: rightColumn ? [dock, right] : [dock])])
        home.resourceID = "ws_home"
        home.kind = "home"
        snapshot.topology.workspaces.append(home)
        return snapshot
    }

    func install(_ snapshot: ControlSnapshot = Self.homeSnapshot()) -> (ControlRouter, OpeningExecutor) {
        let executor = OpeningExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor)
        executor.router.withLock { $0 = router }
        BrowserPageService(engine: NoEngine()).install(on: router)
        router.snapshots.publish { $0 = snapshot }
        return (router, executor)
    }

    func right(_ router: ControlRouter, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(method: "browser.page.right", params: params))
    }

    @Test func theShownBrowserTabOfTheHomeRightColumnIsTheTarget() async throws {
        let (router, executor) = install()
        let result = try await right(router, ["agent": "Chief"]).get()
        #expect(result["tab"] == "tab_user")
        #expect(result["pane"] == .string(Self.rightPane))
        #expect(result["workspace"] == "ws_home")
        #expect(result["created"] == false)
        #expect(executor.count == 0)
    }

    @Test func anotherAgentCannotDriveATabTheChiefHolds() async throws {
        let (router, _) = install()
        _ = try await right(router, ["agent": "Chief"]).get()
        let refused = await right(router, ["agent": "Cloud Chief"])
        #expect(refused.failure?.code == "lease_held")
        #expect(refused.failure?.data?["holder"] == "Chief")
        // The holder itself keeps the tab.
        #expect(try await right(router, ["agent": "Chief"]).get()["tab"] == "tab_user")
    }

    @Test func aNavigationByAnotherAgentOpensItsOwnTabInTheRightColumn() async throws {
        let (router, executor) = install()
        _ = try await right(router, ["agent": "Chief"]).get()
        let opened = try await right(router, ["agent": "Cloud Chief", "url": "https://cmux.com/"]).get()
        #expect(opened["tab"] == "tab_new1")
        #expect(opened["created"] == true)
        #expect(opened["navigated"] == true)
        let run = try #require(executor.last)
        #expect(run.actionID == "openBrowser")
        #expect(run.focus == false)
        #expect(run.arguments["url"]?.json == "https://cmux.com/")
        // Aimed at the right column, never the dock.
        #expect(["tab_markdown", "tab_user"].contains(run.target?.id ?? ""))
        // Its tab from now on, without a URL too; the Chief keeps the user's tab.
        #expect(try await right(router, ["agent": "Cloud Chief"]).get()["tab"] == "tab_new1")
        #expect(try await right(router, ["agent": "Chief"]).get()["tab"] == "tab_user")
        #expect(executor.count == 1)
    }

    @Test func aNavigationNeverTakesOverTheUsersTabUnasked() async throws {
        let (router, executor) = install()
        // No agent holds anything yet: a URL still opens the agent's own tab.
        let opened = try await right(router, ["agent": "Chief", "url": "https://cmux.com/"]).get()
        #expect(opened["tab"] == "tab_new1")
        #expect(executor.count == 1)
        // Its own tab now: a second navigation reuses it (the CLI navigates it).
        let again = try await right(router, ["agent": "Chief", "url": "https://cmux.com/docs"]).get()
        #expect(again["tab"] == "tab_new1")
        #expect(again["created"] == false)
        #expect(again["navigated"] == false)
        #expect(executor.count == 1)
    }

    @Test func withNoColumnRightOfTheChatNothingOpensInTheDock() async {
        let (router, executor) = install(Self.homeSnapshot(rightColumn: false))
        let refused = await right(router, ["agent": "Chief", "url": "https://cmux.com/"])
        #expect(refused.failure?.code == "not_found")
        #expect(refused.failure?.data?["dock_pane"] == .string(Self.dockPane))
        #expect(executor.count == 0)
    }

    @Test func releaseHandsTheTabToTheNextAgent() async throws {
        let (router, _) = install()
        _ = try await right(router, ["agent": "Chief"]).get()
        let released = try await right(router, ["agent": "Chief", "release": true]).get()
        #expect(released["released"] == ["tab_user"])
        #expect(try await right(router, ["agent": "Cloud Chief"]).get()["tab"] == "tab_user")
    }
}

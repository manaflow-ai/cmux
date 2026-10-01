@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `browser.page.tabs|new_tab|select|close` (the old `cmux browser tab
/// list|new|switch|close`): listing reads one workspace's app browser tabs,
/// and the others run the registry action on a tab checked to be an app
/// browser tab. Before, app browser tabs had no tab verbs of their own.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageTabsTests {
    struct NoEngine: BrowserPageEngine {
        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue { [:] }
    }

    static func action(_ id: String, _ arguments: [ControlArgumentInfo] = []) -> ControlActionInfo {
        ControlActionInfo(id: id, title: id, category: "tab", categoryTitle: "Tabs", cliName: "tab " + id, symbol: "globe", keywords: [],
                          shortcut: nil, shortcutConfig: nil, arguments: arguments, targets: ["tab"], requiresMask: 0, requires: [],
                          isBound: true, isDebugOnly: false, mainMenu: nil)
    }

    func install() -> (ControlRouter, RecordingExecutor) {
        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor)
        BrowserPageService(engine: NoEngine()).install(on: router)
        var snapshot = ControlSnapshot.sample()
        snapshot.catalog = ControlCatalog(actions: [
            Self.action("openBrowser", [ControlArgumentInfo(name: "url", title: "URL", kind: .string, isRequired: false)]),
            Self.action("tab.focus"), Self.action("closeTab"),
        ], targetKinds: ["tab"], debugActionsAvailable: false)
        let docs = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Docs", url: "https://cmux.com/docs")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(docs)
        let elsewhere = ControlTabInfo(id: "tab_0456beef", surface: "21", kind: "browser", title: "Other", url: "https://example.com/")
        let pane = ControlPaneInfo(id: "pane-2", handle: "8", selectedTabID: "tab_0456beef", tabs: [elsewhere])
        snapshot.topology.workspaces.append(ControlWorkspaceInfo(id: "ws-2", handle: "3", name: "Second",
                                                                 screens: [ControlScreenInfo(id: "screen-2", handle: "4", panes: [pane])]))
        router.snapshots.publish { $0 = snapshot }
        return (router, executor)
    }

    func ids(_ result: JSONValue) -> [String] {
        guard case .array(let tabs)? = result["tabs"] else { return [] }
        return tabs.compactMap { $0["id"]?.stringValue }
    }

    @Test func listsTheBrowserTabsOfOneWorkspaceOrAll() async throws {
        let (router, _) = install()
        // The focused workspace (its focused tab is a terminal, which is not listed).
        let focused = try await router.handle(ControlRequest(method: "browser.page.tabs")).get()
        #expect(ids(focused) == ["tab_0123abcd"])
        if case .array(let tabs)? = focused["tabs"] {
            #expect(tabs.first?["url"] == "https://cmux.com/docs")
            #expect(tabs.first?["workspace"] == "ws-1")
            #expect(tabs.first?["focused"] == false)
        }
        let other = try await router.handle(ControlRequest(method: "browser.page.tabs", params: ["tab": "tab_0456"])).get()
        #expect(ids(other) == ["tab_0456beef"])
        let all = try await router.handle(ControlRequest(method: "browser.page.tabs", params: ["all": true])).get()
        #expect(ids(all) == ["tab_0123abcd", "tab_0456beef"])
    }

    @Test func selectCloseAndOpenRunTheTabActionsOnTheBrowserTab() async throws {
        let (router, executor) = install()
        let selected = try await router.handle(ControlRequest(method: "browser.page.select", params: ["tab": "tab_0456", "wait": false])).get()
        #expect(selected["tab"] == "tab_0456beef")
        #expect(selected["ran"] == true)
        #expect(executor.last == ControlActionRequest(actionID: "tab.focus", target: ControlTargetRef(kind: "tab", id: "tab_0456beef")))
        _ = try await router.handle(ControlRequest(method: "browser.page.close", params: ["tab": "tab_0123abcd", "wait": false])).get()
        #expect(executor.last == ControlActionRequest(actionID: "closeTab", target: ControlTargetRef(kind: "tab", id: "tab_0123abcd")))
        _ = try await router.handle(ControlRequest(method: "browser.page.new_tab",
                                                   params: ["tab": "tab_0123abcd", "url": "https://cmux.com", "wait": false])).get()
        #expect(executor.last == ControlActionRequest(actionID: "openBrowser", target: ControlTargetRef(kind: "tab", id: "tab_0123abcd"),
                                                      arguments: ["url": .string("https://cmux.com")]))
    }

    @Test func aTerminalIsNeverClosedAsAPage() async {
        let (router, executor) = install()
        // `cmux browser page close` with a terminal focused, and a terminal named outright.
        let refused = await router.handle(ControlRequest(method: "browser.page.close"))
        #expect(refused.failure?.code == "invalid_params")
        let terminal = ControlSnapshot.sample().topology.workspaces[0].screens[0].panes[0].tabs[0].id
        let named = await router.handle(ControlRequest(method: "browser.page.select", params: ["tab": .string(terminal)]))
        #expect(named.failure?.code == "invalid_params")
        #expect(executor.requests.withLock { $0 }.isEmpty)
    }

    @Test func theIdempotencyKeyTravelsWithTheRun() async throws {
        let (router, executor) = install()
        _ = try await router.handle(ControlRequest(method: "browser.page.select",
                                                   params: ["tab": "tab_0456", "wait": false, "idempotency_key": "k1"])).get()
        // The same key for a different run is refused, so it reached action.run.
        let reused = await router.handle(ControlRequest(method: "browser.page.close",
                                                        params: ["tab": "tab_0123abcd", "wait": false, "idempotency_key": "k1"]))
        #expect(reused.failure?.code == "idempotency_conflict")
        #expect(executor.requests.withLock { $0.count } == 1)
    }
}

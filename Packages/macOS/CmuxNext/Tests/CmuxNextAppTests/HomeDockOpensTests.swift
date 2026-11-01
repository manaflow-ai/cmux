import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// home-chief-pane.md H1 and H5. Leo 2026-10-21: "JUST MAKE THE TAB FUCKING THING SHOW UP ON THE MAIN
/// PANE TOO". Home's pinned dock takes the tabs a person drags in (`allow_tabs`), but nothing opens in
/// it: a terminal, browser, file or page tab the CLI, MCP, a script or the app makes there moves to a
/// column right of it, and an open in the background leaves the focus in Home.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HomeDockOpensTests {
    /// Home's lone dock as the app makes it, taking tabs (`allow_tabs`) and focused.
    private static func openHome(_ services: AppServices, _ connection: DaemonConnection) async throws
        -> (window: WindowController, home: WorkspaceModel, dock: PaneController) {
        let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
        let dock = try #require(HomeSplitKeysTests.panes(home).first)
        try await PasswordManagerRouteTests.until({ Self.flag(home, dock)?.allowsTabs == true }, report: {
            "Home's dock: \(String(describing: Self.flag(home, dock)))"
        })
        return (window, home, try #require(services.paneController(for: dock)))
    }

    private static func flag(_ home: WorkspaceModel, _ dock: PaneModel) -> DockSnapshot? {
        home.screens.lazy.flatMap(\.columns).first { $0.layout.paneIDs.contains(dock.handle) }?.dock
    }

    /// Waits until a new tab shows in a column right of the dock while the dock holds only Home's page.
    @discardableResult
    private static func untilBeside(_ home: WorkspaceModel, _ dock: PaneModel, _ what: String) async throws -> PaneModel {
        try await PasswordManagerRouteTests.until({
            let panes = HomeSplitKeysTests.panes(home)
            return panes.count == 2 && panes.first === dock && dock.tabs.count == 1 && panes.last?.tabs.isEmpty == false
        }, report: {
            "\(what): Home's dock holds \(dock.tabs.map { "\($0.kind)" }), \(HomeSplitKeysTests.panes(home).count) pane(s)"
        })
        return try #require(HomeSplitKeysTests.panes(home).last)
    }

    private static func target(_ dock: PaneModel) -> ActionTargetRef { ActionTargetRef(kind: .pane, id: dock.id) }

    /// A terminal or browser tab the CLI, MCP or a script opens in Home's pane opens beside it. A
    /// browser aimed at the focused Home from MCP or a script is an agent's background tab: the
    /// focus stays in Home.
    @Test(arguments: zip(["newSurface", "openBrowser", "openBrowser", "newSurface"],
                         [ActionOrigin.cli, .mcp, .script, .script]))
    func aScriptsNewTabInHomeOpensBesideIt(_ action: String, _ origin: ActionOrigin) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home, dock) = try await Self.openHome(services, connection)
            var arguments: [String: ActionValue] = [:]
            if action == "openBrowser" { arguments["url"] = .string("https://example.com/") }
            #expect(services.registry.perform(ActionID(rawValue: action),
                                              invocation: ActionInvocation(target: Self.target(dock.pane), arguments: arguments, origin: origin)))
            let right = try await Self.untilBeside(home, dock.pane, "\(action) from \(origin)")
            #expect(right.tabs.contains { $0.kind == (action == "openBrowser" ? .browser : .pty) })
            if action == "openBrowser" {
                let screen = try #require(home.screens.first { $0.panes.contains { $0 === dock.pane } })
                #expect(screen.defaultPane == dock.pane.handle, "the daemon's focus left Home")
                #expect(window.focusedPane === dock, "the window's focus left Home")
            }
        }
    }

    /// An open in the background (a Cmd-click) that Home sends beside itself keeps the focus in Home:
    /// the move to the new column asks the daemon to keep it.
    @Test func aBackgroundOpenBesideHomeLeavesTheFocusInHome() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home, dock) = try await Self.openHome(services, connection)
            #expect(dock.newBrowserTab(url: URL(string: "https://example.com/"), background: true))
            try await Self.untilBeside(home, dock.pane, "background browser")
            let screen = try #require(home.screens.first { $0.panes.contains { $0 === dock.pane } })
            // test harness: a late focus event would land within this
            try await Task.sleep(for: .milliseconds(500))
            #expect(screen.defaultPane == dock.pane.handle, "the daemon's focus left Home")
            #expect(window.focusedPane === dock, "the window's focus left Home")
        }
    }

    /// A person's foreground browser tab aimed at the focused Home (the update card's Release Notes
    /// link after an update, New Browser Tab) opens beside it, so Home keeps no tab bar. Lawrence
    /// 2026-10-29 on NIGHTLY 6c1a5ab: "chief in home should not have horizontal tabbar"; the release
    /// page's stand-in tab stayed in Home's dock and brought its strip back.
    @Test(arguments: ["update link", "new tab"])
    func aForegroundBrowserTabFromHomeOpensBesideIt(_ via: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home, dock) = try await Self.openHome(services, connection)
            #expect(window.focusedPane === dock)
            let url = try #require(URL(string: "https://example.com/release"))
            if via == "update link" {
                SidebarCardFeed.openUpdateLink(url, services: services)
            } else {
                #expect(dock.newBrowserTab(url: url))
            }
            let right = try await Self.untilBeside(home, dock.pane, via)
            #expect(right.tabs.contains { $0.kind == .browser })
            #expect(dock.view.hidesStrip, "Home's dock shows a tab bar")
        }
    }

    /// A browser creator that delegates Home placement through `then` must not select its daemon
    /// tab after that callback starts: OutboundTab owns the hold until the move lands.
    @Test func aBrowserPlacementCallbackKeepsTheHomeStripHiddenBeforeTheMove() async throws {
        try await PasswordManagerRouteTests.withApp { services, homeConnection in
            let (window, home, dock) = try await Self.openHome(services, homeConnection)
            dock.syncStripFromStore()
            guard let homeTab = dock.stripModel.selectedID else {
                Issue.record("Home did not have a selected page before browser placement")
                return
            }
            var callbackSawHiddenStrip = false
            guard let placed = HomeDockOpens.placing(dock.pane, services: services, focus: true, then: { _ in
                dock.syncStripFromStore()
                #expect(dock.stripModel.tabs.map(\.id) == [homeTab], "browser selected itself before placement")
                #expect(dock.stripModel.selectedID == homeTab, "browser selection released Home's outbound hold")
                callbackSawHiddenStrip = true
            }) else {
                Issue.record("Home did not provide a browser placement callback")
                return
            }
            #expect(dock.newBrowserTab(url: URL(string: "https://example.com/"), placementOwner: true, then: placed))
            let right = try await Self.untilBeside(home, dock.pane, "browser placement callback")
            #expect(callbackSawHiddenStrip)
            #expect(right.tabs.contains { $0.kind == .browser })
            #expect(dock.view.hidesStrip)
            try await PasswordManagerRouteTests.until({ window.focusedPane?.pane === right }, report: {
                "browser placement callback did not focus its destination"
            })
        }
    }

    /// A foreground creator must not select either its stand-in or its real tab in Home before
    /// placement. OutboundTab deliberately releases selected tabs (a person's explicit selection).
    @Test(arguments: ["optimistic terminal", "typed terminal", "page"])
    func aForegroundCreatorKeepsHomesStripHiddenUntilPlacement(_ kind: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home, dock) = try await Self.openHome(services, connection)
            dock.syncStripFromStore()
            guard let homeTab = dock.stripModel.selectedID else {
                Issue.record("Home did not have a selected page before placement")
                return
            }
            var sawPlacement = false
            guard let placed = HomeDockOpens.placing(dock.pane, services: services, focus: true, then: { _ in
                // Runs before HomeDockOpens moves the tab: a later final-state check misses the flash.
                dock.syncStripFromStore()
                #expect(dock.stripModel.tabs.map(\.id) == [homeTab], "the created tab appeared in Home before placement")
                #expect(dock.stripModel.selectedID == homeTab, "the creator selected its real tab in Home")
                sawPlacement = true
            }) else {
                Issue.record("Home did not provide a placement callback")
                return
            }
            if kind == "page" {
                #expect(services.pages.openStoreTab(.inbox, in: dock, window: window, focus: true, created: placed) != nil)
            } else {
                // A non-nil typing value uses the asynchronous path, without an optimistic tab.
                dock.newTerminalTab(typing: kind == "typed terminal" ? ":\r" : nil, placementOwner: true, then: placed)
            }
            dock.syncStripFromStore()
            #expect(dock.stripModel.tabs.map(\.id) == [homeTab], "the provisional tab appeared in Home")
            #expect(dock.stripModel.selectedID == homeTab, "the creator selected its provisional tab in Home")
            let right = try await Self.untilBeside(home, dock.pane, kind)
            #expect(sawPlacement)
            #expect(dock.view.hidesStrip)
            try await PasswordManagerRouteTests.until({ window.focusedPane?.pane === right }, report: {
                "the foreground \(kind) did not take focus in its destination"
            })
        }
    }

    /// The create reply is not the end of a terminal open from Home: its move is another async
    /// step. Hold the store listing to leave placement pending, then let the move fail normally.
    /// Both optimistic and non-optimistic creators resolve their ticket immediately after `placed`.
    @Test func aHomePlacementKeepsCreationInputPendingAfterTheCreateReply() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, _, dock) = try await Self.openHome(services, connection)
            let shell = try #require(window.window)
            let content = try #require(dock.workspace)
            let input = services.keyRouter.creationInputCoordinator
            let creation = try #require(input.begin(in: shell, generation: content.beginFocusIntent()))
            let pending = ProvisionalTab()
            let placed = try #require(HomeDockOpens.placing(dock.pane, services: services, focus: true, then: nil))
            // The surface is not listed yet, so LinkOpener waits rather than starting the move.
            placed(pending.surface)
            input.resolve(creation, landed: true, in: shell)
            await Task.yield()
            #expect(input.hasPendingCreation(in: shell), "create reply released the keys before placement")
            #expect(content.focus.state.expectation?.awayFrom == dock.paneKey,
                    "the old Home terminal may not satisfy destination focus")

            // List a stand-in the real daemon does not own: the attempted move fails and releases
            // the placement hold through its ordinary failure fallback, not the expiration timer.
            let transaction = ClientTransactionID.generate()
            defer { services.daemon.store.rejectIntent(transaction) }
            services.daemon.store.intend(.createTab(pane: dock.pane.handle, provisional:
                TabSnapshot(surface: pending.surface, tabResourceID: ResourceID(rawValue: pending.id))), transaction: transaction)
            try await PasswordManagerRouteTests.until({ !input.hasPendingCreation(in: shell) }, report: {
                "the failed Home placement kept its input ticket"
            })
        }
    }

    /// A foreground page kept its provisional tab unselected to avoid flashing Home's strip.
    /// If creation fails, the same local view must become visible; a background or superseded
    /// request must leave the old selection alone.
    @Test(arguments: ["foreground", "background", "superseded"])
    func aFailedHomePageOpenRevealsOnlyItsCurrentForegroundFallback(_ request: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, _, dock) = try await Self.openHome(services, connection)
            let original = try #require(dock.stripModel.selectedID)
            let create = services.pages.createStoreTab
            var fail: CheckedContinuation<Void, Never>?
            services.pages.createStoreTab = { _, _, _, _, _ in
                await withCheckedContinuation { fail = $0 }
                throw DaemonError.notConnected
            }
            defer { services.pages.createStoreTab = create; fail?.resume() }
            let view = try #require(services.pages.openStoreTab(.inbox, in: dock, window: window,
                                                              focus: request != "background"))
            try await PasswordManagerRouteTests.until({ fail != nil })
            #expect(dock.stripModel.selectedID == original, "the provisional page selected itself in Home")
            if request == "superseded" { _ = dock.workspace?.beginFocusIntent() }
            let reply = fail
            fail = nil
            reply?.resume()
            try await PasswordManagerRouteTests.until({ services.pages.tabIDs(in: dock.paneKey).contains(view.key) })
            if request == "foreground" {
                try await PasswordManagerRouteTests.until({ dock.currentTabKey == view.key }, report: {
                    "the failed foreground page stayed hidden behind \(dock.currentTabKey ?? "nil")"
                })
            } else {
                #expect(dock.stripModel.selectedID == original, "a \(request) failure stole focus")
            }
            #expect(services.pages.existingView(view.key) === view, "fallback replaced the page's view")
        }
    }

    /// A page the engine already made and the pane adopts (Duplicate Tab on a browser tab dragged into
    /// Home, a popup) opens beside Home too.
    @Test func anAdoptedPageInHomeOpensBesideIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (_, home, dock) = try await Self.openHome(services, connection)
            let url = URL(string: "https://example.com/")
            let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab(initialURL: url)
            #expect(dock.newBrowserTab(url: url, inherited: BrowserEngineTag.webkit.rawValue, adopting: page))
            let right = try await Self.untilBeside(home, dock.pane, "adopted page")
            #expect(right.tabs.contains { $0.kind == .browser })
        }
    }

    /// `cmux file open` aimed at Home's pane, and an app page (the Inbox) shown while Home has the
    /// focus, open beside it.
    @Test(arguments: ["file", "page"])
    func aFileOrPageFromHomeOpensBesideIt(_ kind: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home, dock) = try await Self.openHome(services, connection)
            if kind == "file" {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("home-dock-\(UUID().uuidString.prefix(8)).txt")
                try "Home opens nothing in itself\n".write(to: file, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: file) }
                #expect(services.registry.perform("file.open", invocation: ActionInvocation(
                    target: Self.target(dock.pane), arguments: ["path": .string(file.path)], origin: .cli)))
                try await Self.untilBeside(home, dock.pane, "file open")
            } else {
                #expect(services.pages.openNew(.inbox, in: window, focus: false) != nil)
                let right = try await Self.untilBeside(home, dock.pane, "Inbox page")
                #expect(right.tabs.contains { $0.page == InternalPageID.inbox.rawValue })
            }
        }
    }

    /// With no daemon browser tabs, the app's own (WebKit) tab never lands in Home's dock either: it
    /// opens in the pane right of Home, or, with Home alone, is refused.
    @Test func aSessionLocalBrowserTabNeverLandsInHome() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home, dock) = try await Self.openHome(services, connection)
            let browserTabs = services.cache.browserTabs
            let serves = browserTabs.serves
            browserTabs.serves = { _ in false }
            defer { browserTabs.serves = serves }
            let url = URL(string: "https://example.com/")
            _ = dock.newBrowserTab(url: url)
            #expect(window.state.localBrowserTabs[dock.paneKey].isEmpty, "a session-local tab landed in Home alone")
            // A terminal beside Home, then Home focused again: the tab opens in that pane.
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: terminal))
            try await Self.untilBeside(home, dock.pane, "split")
            let right = try #require(HomeSplitKeysTests.panes(home).last.flatMap { services.paneController(for: $0) })
            if let content = window.content, let id = content.handles.paneIDs[dock.pane.handle] { PaneHandlers.focus(id, in: content) }
            #expect(dock.newBrowserTab(url: url))
            #expect(window.state.localBrowserTabs[dock.paneKey].isEmpty, "a session-local tab landed in Home")
            #expect(window.state.localBrowserTabs[right.paneKey].count == 1, "the tab did not open right of Home")
        }
    }
}

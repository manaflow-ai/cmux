import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
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

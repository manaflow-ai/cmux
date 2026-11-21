import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Right-click a pane's tab strip, New Tab with Browser Profile…, pick a profile: a browser tab of
/// that profile opens in that pane (user report: the row "does nothing", in Home and elsewhere).
/// The row runs `browserProfile.newTab` on the pane with no profile; the palette asks for it (the
/// registry's argument collector), as a person's pick there runs the action again with it. Runs
/// the app's action registry and palette against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct BrowserProfileNewTabMenuTests {
    private static func rows(_ menu: NSMenu) -> [NSMenuItem] {
        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        return all(menu.items)
    }

    /// The harness retains its services after closing its shell windows. Retire cached browser
    /// pages too, so their Page Info and Extensions panels close on success and on an early throw.
    private static func close(_ services: AppServices, palettePanel: NSWindow?) {
        let panel = palettePanel ?? services.palette.visiblePanel
        services.palette.hide()
        panel?.close()
        for key in Array(services.cache.browsers.keys) { services.cache.release(key) }
    }

    /// The browser tabs of `pane` in the daemon's records.
    private static func browserTabs(_ pane: PaneController, _ services: AppServices) -> [TabModel] {
        services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).filter { $0.id == pane.pane.id }.flatMap(\.tabs).filter { $0.kind == .browser }
    }

    @Test func theStripMenusNewTabWithBrowserProfileOpensATabOfThePickedProfile() async throws {
        try await PinnedPageTests.withApp { services, _ in
            var palettePanel: NSWindow?
            defer { Self.close(services, palettePanel: palettePanel) }
            services.palette.bindRegistryActions()
            let pane = try #require(services.windows.active?.workspaceContent?.panes.values.first)
            let before = Set(Self.browserTabs(pane, services).map(\.id))
            let menu = try #require(pane.contextMenu(for: .emptyStrip))
            let row = try #require(Self.rows(menu).first { ActionRegistry.menuRun(of: $0)?.id == "browserProfile.newTab" },
                                   "the strip menu has no New Tab with Browser Profile row")
            let run = try #require(ActionRegistry.menuRun(of: row))
            #expect((row.target as? NSMenuItemValidation)?.validateMenuItem(row) == true, "the row is disabled")

            // What `ActionMenuTarget.performAction` runs for the click.
            var refusals: [String] = []
            let previous = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in refusals.append(reason); previous?(reason, quiet) }
            var ran = false
            let clickRefusal = services.registry.capturingRefusal {
                ran = services.registry.perform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments))
            }
            #expect(ran, "the click did not run")
            #expect(clickRefusal == nil, "the click refused: \(clickRefusal ?? "")")

            // Retain the panel before waiting: a timeout must close it too.
            palettePanel = services.palette.visiblePanel
            // The palette asks which profile; the person picks the default one.
            try await PinnedPageTests.until({ services.palette.model.rows.contains { $0.item.id == "option:\(BrowserProfileRecord.defaultID)" } },
                                            report: { "palette visible \(services.palette.isVisible), rows \(services.palette.model.rows.map(\.item.id)), refusals \(refusals)" })
            palettePanel = palettePanel ?? services.palette.visiblePanel
            services.palette.model.activate(rowID: "option:\(BrowserProfileRecord.defaultID)")

            try await PinnedPageTests.until({ Self.browserTabs(pane, services).contains { !before.contains($0.id) } }, within: .seconds(30), report: {
                "refusals \(refusals); tabs \(Self.browserTabs(pane, services).map(\.id)); " + WindowStateReport.describe(services, page: nil)
            })
            let made = try #require(Self.browserTabs(pane, services).first { !before.contains($0.id) })
            #expect(services.browserProfiles.profileID(ofTab: made) == BrowserProfileRecord.defaultID)
            services.registry.refusalObserver = previous
        }
    }

    /// The same on Home (the docked Home: the store's home workspace, Home's page in a left chat
    /// dock and a normal pane on its right): each of its panes' strip menus opens the tab.
    @Test func onHomeEveryPanesStripMenuOpensATabOfThePickedProfile() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            var palettePanel: NSWindow?
            defer { Self.close(services, palettePanel: palettePanel) }
            services.palette.bindRegistryActions()
            let window = try #require(services.windows.active)
            services.home.ensureHomeWorkspace(connection)
            try await PasswordManagerRouteTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60),
                                                       report: { services.home.homeWorkspaceStep })
            let home = try #require(services.home.homeWorkspace)
            #expect(services.registry.perform("home.show", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == home.id && window.focusedPane != nil }, report: {
                "workspace \(String(describing: window.state.workspaceID)), page \(String(describing: window.state.page))"
            })
            var refusals: [String] = []
            let previous = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in refusals.append(reason); previous?(reason, quiet) }
            defer { services.registry.refusalObserver = previous }
            let panes = try #require(window.workspaceContent?.panes.values.map { $0 }).sorted { $0.paneKey < $1.paneKey }
            for pane in panes {
                refusals.removeAll()
                let before = Set(Self.browserTabs(pane, services).map(\.id))
                let menu = try #require(pane.contextMenu(for: .emptyStrip))
                guard let row = Self.rows(menu).first(where: { ActionRegistry.menuRun(of: $0)?.id == "browserProfile.newTab" }),
                      let run = ActionRegistry.menuRun(of: row) else {
                    Issue.record("pane \(pane.paneKey): the strip menu has no New Tab with Browser Profile row")
                    continue
                }
                #expect((row.target as? NSMenuItemValidation)?.validateMenuItem(row) == true, "pane \(pane.paneKey): the row is disabled")
                var ran = false
                let clickRefusal = services.registry.capturingRefusal {
                    ran = services.registry.perform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments))
                }
                #expect(ran && clickRefusal == nil, "pane \(pane.paneKey): the click refused: \(clickRefusal ?? "") ran \(ran)")
                palettePanel = palettePanel ?? services.palette.visiblePanel
                let option = "option:\(BrowserProfileRecord.defaultID)"
                try await PinnedPageTests.until({ services.palette.model.rows.contains { $0.item.id == option } },
                                                report: { "pane \(pane.paneKey): palette \(services.palette.isVisible), rows \(services.palette.model.rows.map(\.item.id)), refusals \(refusals)" })
                palettePanel = palettePanel ?? services.palette.visiblePanel
                services.palette.model.activate(rowID: option)
                try await PinnedPageTests.until({ Self.browserTabs(pane, services).contains { !before.contains($0.id) } }, within: .seconds(30), report: {
                    "pane \(pane.paneKey): refusals \(refusals); tabs \(Self.browserTabs(pane, services).map(\.id)); " + WindowStateReport.describe(services)
                })
            }
        }
    }

    /// Right-click a browser tab's profile badge (its omnibar) on Home, where the focus is in Home's
    /// chat dock: New Tab with Browser Profile opens its tab in the pane of the right-clicked tab, not
    /// in the focused dock (`AppServices.profileBadgeMenu`). The dock opens nothing in itself: a new tab
    /// aimed at it goes to a new column beside it (`PaneBrowserTabOpener`, HomeDockOpens), so the
    /// right-clicked tab is in the column right of the dock. (Manage Extensions shares the pane lookup;
    /// it needs Chromium.)
    @Test func theProfileBadgeMenuOpensItsTabInTheRightClickedTabsPane() async throws {
        let action = "browserProfile.newTab"
        try await PasswordManagerRouteTests.withApp { services, connection in
            defer { Self.close(services, palettePanel: nil) }
            let window = try #require(services.windows.active)
            services.home.ensureHomeWorkspace(connection)
            try await PasswordManagerRouteTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60),
                                                       report: { services.home.homeWorkspaceStep })
            let home = try #require(services.home.homeWorkspace)
            #expect(services.registry.perform("home.show", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == home.id && window.focusedPane != nil }, report: {
                "workspace \(String(describing: window.state.workspaceID)), page \(String(describing: window.state.page))"
            })
            // Each pane is the daemon's, not a split's stand-in (`ProvisionalPane`), whose handle the daemon
            // does not know ("new-frontend-browser-tab failed: unknown pane" on a loaded host).
            @MainActor func isDaemons(_ pane: PaneController?) -> Bool {
                pane.map { !$0.pane.tabs.isEmpty && $0.pane.tabs.allSatisfy { !ProvisionalTab.isProvisional(surface: $0.surface) } } ?? false
            }
            // Home shows its chat dock, focused and laid out as the dock (a split from it opens a column beside it).
            try await PasswordManagerRouteTests.until({ isDaemons(window.focusedPane) && window.focusedPane.map { ChatDockRules.isChatDock($0.pane, services: services) } == true },
                                                       report: { "Home's focused pane is not its laid-out chat dock yet: " + WindowStateReport.describe(services) })
            let dock = try #require(window.focusedPane)
            let content = try #require(window.workspaceContent)
            // Split Right from the dock: a pane in a new column right of it, which takes the focus.
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ isDaemons(window.focusedPane) && window.focusedPane !== dock },
                                                       report: { "panes \(content.panes.keys.map { "\($0)" }), focused \(window.focusedPane?.paneKey ?? "none")" })
            let pane = try #require(window.focusedPane)
            // A browser tab in that pane, listed by its strip (the menu's run targets the tab by its strip).
            let surface = try await connection.newFrontendBrowserTab(url: "https://example.com/", engine: .webkit, in: pane.pane.handle, activate: false).surface
            try await PasswordManagerRouteTests.until({ services.daemon.store.tab(surface: surface) != nil && services.cache.tabModel(services.daemon.store.tab(surface: surface)?.id ?? "") != nil },
                                                       report: { WindowStateReport.describe(services, surface: surface) })
            let tab = try #require(services.daemon.store.tab(surface: surface))
            try await PasswordManagerRouteTests.until({ pane.stripModel.tab(StripTabID(tab.id)) != nil },
                                                       report: { "the strip of \(pane.paneKey) does not list \(tab.id) yet" })
            // The focus goes back to the dock: the right-clicked tab is in the pane without the focus.
            PaneHandlers.focus(dock.layoutPaneID, in: content)
            try await PasswordManagerRouteTests.until({ window.focusedPane === dock }, report: { "the dock did not take the focus back" })
            let before = Set(services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
            let menu = try #require(services.cache.profileBadgeMenu?(tab.id), "the badge has no menu")
            let row = try #require(Self.rows(menu).first { ActionRegistry.menuRun(of: $0)?.id == ActionID(rawValue: action) }, "the badge menu has no \(action) row")
            let run = try #require(ActionRegistry.menuRun(of: row))
            let refusal = services.registry.capturingRefusal {
                _ = services.registry.perform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments))
            }
            #expect(refusal == nil, "\(action) refused: \(refusal ?? "")")
            @MainActor func made() -> [String] {
                services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap { model in
                    model.tabs.filter { $0.kind == .browser && !before.contains($0.id) }.map { "\($0.id) in \(model.id)" }
                }
            }
            try await PasswordManagerRouteTests.until({ Self.browserTabs(pane, services).contains { !before.contains($0.id) } }, within: .seconds(30), report: {
                "no new tab in the right-clicked tab's pane \(pane.paneKey) (the dock \(dock.paneKey) is focused); new browser tabs: \(made())"
            })
        }
    }
}

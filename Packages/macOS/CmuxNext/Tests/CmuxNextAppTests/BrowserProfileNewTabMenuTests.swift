import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import Testing

/// Right-click a pane's tab strip, New Tab with Browser Profile…, pick a profile: a browser tab of
/// that profile opens in that pane (user report: the row "does nothing", in Home and elsewhere).
/// The row runs `browserProfile.newTab` on the pane with no profile; the palette asks for it (the
/// registry's argument collector), as a person's pick there runs the action again with it. Runs
/// the app's action registry and palette against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct BrowserProfileNewTabMenuTests {
    private static func rows(_ menu: NSMenu) -> [NSMenuItem] {
        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        return all(menu.items)
    }

    /// The browser tabs of `pane` in the daemon's records.
    private static func browserTabs(_ pane: PaneController, _ services: AppServices) -> [TabModel] {
        services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).filter { $0.id == pane.pane.id }.flatMap(\.tabs).filter { $0.kind == .browser }
    }

    @Test func theStripMenusNewTabWithBrowserProfileOpensATabOfThePickedProfile() async throws {
        try await PinnedPageTests.withApp { services, _ in
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

            // The palette asks which profile; the person picks the default one.
            try await PinnedPageTests.until({ services.palette.model.rows.contains { $0.item.id == "option:\(BrowserProfileRecord.defaultID)" } },
                                            report: { "palette visible \(services.palette.isVisible), rows \(services.palette.model.rows.map(\.item.id)), refusals \(refusals)" })
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
                let option = "option:\(BrowserProfileRecord.defaultID)"
                try await PinnedPageTests.until({ services.palette.model.rows.contains { $0.item.id == option } },
                                                report: { "pane \(pane.paneKey): palette \(services.palette.isVisible), rows \(services.palette.model.rows.map(\.item.id)), refusals \(refusals)" })
                services.palette.model.activate(rowID: option)
                try await PinnedPageTests.until({ Self.browserTabs(pane, services).contains { !before.contains($0.id) } }, within: .seconds(30), report: {
                    "pane \(pane.paneKey): refusals \(refusals); tabs \(Self.browserTabs(pane, services).map(\.id)); " + WindowStateReport.describe(services)
                })
            }
        }
    }

    /// Right-click a browser tab's profile badge (its omnibar) on Home, where the focus is in the
    /// other pane: New Tab with Browser Profile opens its tab in the pane of the right-clicked tab,
    /// not in the focused pane. (Manage Extensions shares the pane lookup; it needs Chromium.)
    @Test func theProfileBadgeMenuOpensItsTabInTheRightClickedTabsPane() async throws {
        let action = "browserProfile.newTab"
        try await PasswordManagerRouteTests.withApp { services, connection in
            let window = try #require(services.windows.active)
            services.home.ensureHomeWorkspace(connection)
            try await PasswordManagerRouteTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60),
                                                       report: { services.home.homeWorkspaceStep })
            let home = try #require(services.home.homeWorkspace)
            #expect(services.registry.perform("home.show", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == home.id && window.focusedPane != nil }, report: {
                "workspace \(String(describing: window.state.workspaceID)), page \(String(describing: window.state.page))"
            })
            // A second pane takes the focus (Split Right), so the first one is not focused. Each is the
            // daemon's pane, not a split's stand-in (`ProvisionalPane`), whose handle the daemon does not know
            // ("new-frontend-browser-tab failed: unknown pane" on a loaded host).
            @MainActor func isDaemons(_ pane: PaneController?) -> Bool {
                pane.map { !$0.pane.tabs.isEmpty && $0.pane.tabs.allSatisfy { !ProvisionalTab.isProvisional(surface: $0.surface) } } ?? false
            }
            try await PasswordManagerRouteTests.until({ isDaemons(window.focusedPane) }, report: { "the focused pane is not the daemon's yet" })
            let first = try #require(window.focusedPane)
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ (window.workspaceContent?.panes.count ?? 0) > 1 && isDaemons(window.focusedPane) && window.focusedPane !== first },
                                                       report: { "panes \(window.workspaceContent?.panes.keys.map { "\($0)" } ?? []), focused \(window.focusedPane?.paneKey ?? "none")" })
            let focused = try #require(window.focusedPane)
            let pane = first
            // A browser tab in the pane without the focus; the focus stays where it is.
            let surface = try await connection.newFrontendBrowserTab(url: "https://example.com/", engine: .webkit, in: pane.pane.handle, activate: false).surface
            try await PasswordManagerRouteTests.until({ services.daemon.store.tab(surface: surface) != nil && services.cache.tabModel(services.daemon.store.tab(surface: surface)?.id ?? "") != nil },
                                                       report: { WindowStateReport.describe(services, surface: surface) })
            let tab = try #require(services.daemon.store.tab(surface: surface))
            // The menu's run targets the tab by its strip: wait until the pane's strip lists it.
            try await PasswordManagerRouteTests.until({ pane.stripModel.tab(StripTabID(tab.id)) != nil },
                                                       report: { "the strip of \(pane.paneKey) does not list \(tab.id) yet" })
            #expect(window.focusedPane === focused, "opening the tab moved the focus")
            let before = Set(Self.browserTabs(pane, services).map(\.id))
            let menu = try #require(services.cache.profileBadgeMenu?(tab.id), "the badge has no menu")
            let row = try #require(Self.rows(menu).first { ActionRegistry.menuRun(of: $0)?.id == ActionID(rawValue: action) }, "the badge menu has no \(action) row")
            let run = try #require(ActionRegistry.menuRun(of: row))
            let refusal = services.registry.capturingRefusal {
                _ = services.registry.perform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments))
            }
            #expect(refusal == nil, "\(action) refused: \(refusal ?? "")")
            try await PasswordManagerRouteTests.until({ Self.browserTabs(pane, services).contains { !before.contains($0.id) } }, within: .seconds(30), report: {
                "no new tab in the right-clicked tab's pane \(pane.paneKey); focused pane \(focused.paneKey) has \(Self.browserTabs(focused, services).map(\.id))"
            })
        }
    }
}

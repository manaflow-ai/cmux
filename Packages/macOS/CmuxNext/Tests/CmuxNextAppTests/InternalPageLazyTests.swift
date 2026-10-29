import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTasks
import Foundation
import Testing

/// Lazy page tabs: a page tab nobody sees costs no page. Its provider makes the
/// tab's view the first time a pane shows the tab, as Chrome loads a restored background tab only
/// when it is activated (chrome/browser/sessions/tab_loader.cc, `NavigationController::LoadIfNecessary`).
/// The strip still lists the tab, with its title and icon, from the first turn.
@MainActor
final class LazyCountingPage: InternalPageProvider {
    let page: InternalPageID
    let title = "Lazy page"
    let symbol = "doc"
    /// The keys `makeView(for:in:)` was called for, in order.
    private(set) var made: [String] = []
    private(set) var views: [NSView] = []

    init(_ page: InternalPageID) { self.page = page }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        made.append(key)
        let view = NSView()
        views.append(view)
        return view
    }
}

@MainActor
struct InternalPageLazyTests {
    /// 14 restored page tabs, one per workspace the window does not show: the strip names each of
    /// them, and no provider view exists until one shows.
    @Test func restoredPageTabsInBackgroundPanesMakeNoViewUntilOneShows() throws {
        let pages = InternalPageTabStore()
        let provider = LazyCountingPage(InternalPageID(rawValue: "test.lazy-restored"))
        pages.register(provider)
        let store = DaemonStore()
        var workspaces: [WorkspaceSnapshot] = []
        for index in 1...14 {
            var tab = TabSnapshot(surface: SurfaceID(rawValue: UInt64(300 + index)), kind: .conversation, title: "about:blank")
            tab.conversation = ConversationTabRef(page: provider.page.rawValue, route: "route-\(index)")
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(200 + index)), tabs: [tab])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(100 + index)), layout: .leaf(pane.id), panes: [pane])
            workspaces.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index)), key: nil, name: "w\(index)", screens: [screen]))
        }
        store.apply(snapshot: DaemonTree(workspaces: workspaces))
        let tabs = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        try #require(tabs.count == 14)

        for tab in tabs {
            #expect(pages.storeTabItem(tab)?.title == provider.title)
            #expect(TabTitleResolver(pages: pages).title(tab) == provider.title)
        }
        #expect(provider.made.isEmpty, "a restored page tab made its view before it showed")

        let shown = try #require(tabs.first)
        let view = try #require(pages.view(forStoreTab: shown, in: store, local: true, window: nil))
        #expect(provider.made.count == 1)
        #expect(view.content === provider.views.first)
    }
}

/// The same rule through the app's open paths, on a same-tree daemon: a page tab opened without
/// showing it (automation, a script's `openSettings`, a page opened under a top page) makes its
/// view only when the person selects it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct InternalPageLazyAppTests {
    @Test func aBackgroundPageTabMakesNoViewUntilItShows() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            let provider = LazyCountingPage(InternalPageID(rawValue: "test.lazy-background"))
            services.pages.register(provider)

            let view = try #require(services.pages.openNew(provider.page, in: window, focus: false))
            #expect(provider.made.isEmpty, "a page tab opened in the background made its view")
            #expect(services.pages.existingView(view.key) == nil, "an unshown page tab reports a live view")
            // Asked again without showing it: the same tab, still no view.
            #expect(services.pages.show(provider.page, in: window, focus: false) === view)
            #expect(provider.made.isEmpty, "a background show made the tab's view")

            // The person shows it: the provider makes its view once, inside the tab's view.
            #expect(services.pages.show(provider.page, in: window, focus: true) === view)
            try await PasswordManagerRouteTests.until({ provider.made.count == 1 }, report: { "made \(provider.made)" })
            #expect(view.content === provider.views.first)
            #expect(services.pages.existingView(view.key) === view)
            #expect(provider.made.count == 1, "the shown tab made its view again")
        }
    }

    @Test func aPageTabOpenedInAParkedWorkspaceMakesNoViewUntilItIsSelected() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            let provider = LazyCountingPage(InternalPageID(rawValue: "test.lazy-parked"))
            services.pages.register(provider)
            // The window shows a top page: its workspace parks, off screen.
            try #require(window.showTopPage(.page(.stats)), "the stats page did not show as a top page")

            let view = try #require(services.pages.openNew(provider.page, in: window, focus: false))
            #expect(provider.made.isEmpty, "a page tab opened in a parked workspace made its view")

            // The workspace shows again; the new tab is listed and not selected, so it still has no view.
            window.leaveTopPage()
            try await PasswordManagerRouteTests.until({ services.paneController(showingTab: view.key) != nil },
                                                      report: { "no pane lists \(view.key)" })
            let pane = try #require(services.paneController(showingTab: view.key))
            let id = try #require(services.pages.stripID(showing: view.key, in: pane))
            #expect(provider.made.isEmpty, "an unselected page tab made its view when its workspace showed")

            pane.select(id)
            try await PasswordManagerRouteTests.until({ provider.made.count == 1 }, report: { "made \(provider.made)" })
            #expect(view.content === provider.views.first)
        }
    }

    /// Settings, the heaviest React page: an automation open builds no page out of sight, and the
    /// page its first show makes opens on the section the open asked for.
    @Test func settingsOpenedInTheBackgroundMakesItsPageAtItsFirstShowOnTheAskedSection() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            try services.settingsWindow.show(section: .appearance, focus: false)
            let key = try #require(services.pages.keys(of: .settings).first, "the background open made no Settings tab")
            #expect(services.pages.existingView(key) == nil, "a Settings tab opened in the background built its page")

            try await PasswordManagerRouteTests.until({ services.paneController(showingTab: key) != nil },
                                                      report: { "no pane lists \(key)" })
            let pane = try #require(services.paneController(showingTab: key))
            let id = try #require(services.pages.stripID(showing: key, in: pane))
            #expect(services.pages.existingView(key) == nil, "an unselected Settings tab built its page")

            pane.select(id)
            try await PasswordManagerRouteTests.until({ services.pages.existingView(key) != nil },
                                                      report: { "the selected Settings tab never built its page" })
            let page = try #require(services.pages.existingView(key)?.content as? PageWebView)
            #expect(page.route == SettingsWindowService.route(section: .appearance, setting: nil),
                    "the page opened on \(page.route ?? "nil"), not the section the open asked for")
        }
    }

    /// `tasks.showMine` with no Tasks tab yet: the tab's model is made at its first show and still
    /// takes the scope the user run asked for (the open made no model to set it on).
    @Test func tasksShowMineAppliesItsScopeToTheModelItsFirstShowMakes() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            #expect(services.tasks.model == nil)
            try services.tasks.show(scope: .mine, focus: true)
            try await PasswordManagerRouteTests.until({ services.tasks.model != nil },
                                                      report: { "the focused Tasks tab never made its model" })
            #expect(services.tasks.model?.scope == .mine, "the first open's scope was dropped")
        }
    }
}

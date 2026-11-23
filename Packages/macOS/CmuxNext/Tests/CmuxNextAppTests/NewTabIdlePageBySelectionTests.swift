import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextSignposts
import CmuxNextTestSupport
import Foundation
import Testing

/// Which New Tab page view is idle (`AgentTabStore.idlePage`): never the page view of a tab that a pane of a workspace
/// which a window shows has selected, except the tab that the pane of a New Tab key leaves. The surface ledger alone
/// does not decide it: a pane is `visible` in the ledger only after a layout pass of its workspace's view, so the
/// ledger can say `not drawn` for a tab that the window shows.
///
/// Each row starts after one New Workspace key: the window shows that key's workspace on a New Tab page that the
/// person did not touch, with the page view that the window made ahead. The window makes no workspace ahead in the
/// row until the row asks for it (the store's pause of the reservation, as under memory pressure).
///
/// - Rows 1 to 3, after one more New Workspace key (the window shows a workspace that it did not make ahead, whose
///   content it made at that key): a taker with no tab of its own to leave asks for a page view. Row 1: the store
///   shows a new workspace (the store's own call, no window). Row 2: the store makes the next workspace ahead (the
///   call of the window's idle work). Row 3: the window makes its next workspace ahead by its own idle work. Want:
///   the tab that the window shows keeps its page view. Each setup prints what the surface ledger says of that tab.
/// - Row 4, print only: a workspace that went out of view gave its page view to the workspace that the window made
///   ahead, and is shown again. How many page views are built at that show, with an untouched page in another
///   workspace that is out of view, and with none.
/// - Row 5, 2 cases (the left workspace is one that the window made ahead; one whose content it made at its key):
///   one more New Workspace key, with no workspace made ahead and no page in the pool. Want: when the key's call
///   returns with the left workspace still in the window, the tab that its pane has selected has its page view;
///   and no commit of the run loop has the left workspace in the window with an empty pane. It prints how many
///   page views were built and what the ledger said of the left tab before the key.
///
/// Limits. Each page view is a WebKit one (the package's tests have no Chromium host), the pool of pages made ahead
/// is empty, and the rows read which view a tab has, not what a page draws.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabIdlePageBySelectionTests {
    typealias Moves = NewTabHoldMovesItsPageTests

    /// What a row starts with: the window, the tab and the page view that it shows after the key, and the tab and the
    /// workspace that it showed before the key.
    struct Start {
        let controller: WindowController
        let shown: String
        let page: AgentPaneView
        let first: String
        let firstWorkspace: String
        /// The key of the made-ahead workspace's tab before the key (the first name of `shown`).
        let ahead: String
    }

    /// What row 5 counts after each commit of the run loop, from its key on.
    @MainActor final class Commits {
        var counts = false
        var all = 0
        var withAnEmptyPane = 0
    }

    /// The tab that the strip of the window's focused pane has selected (of its first pane with one, before a focus).
    static func selected(_ controller: WindowController) -> String? {
        controller.content?.focusedPane?.stripModel.selectedID?.rawValue
            ?? controller.content?.panes.values.compactMap { $0.stripModel.selectedID?.rawValue }.first
    }

    /// Whether the surface ledger says that a pane draws tab `key` now.
    static func ledgerDraws(_ key: String, _ services: AppServices) -> Bool {
        services.cache.isRendering(key) || services.cache.isRendering(services.agentTabs.resolve(key))
    }

    /// The page views of New Tab pages that the store has now.
    static func pages(_ services: AppServices) -> [AgentPaneView] {
        services.agentTabs.views.values.filter { $0.model.newTab != nil }
    }

    /// Whether the tab that the window shows now has page view `page`: by the strip's selection now, not by a name of
    /// the tab from before (the daemon's answer gives a new tab its last name).
    static func showsPage(_ page: AgentPaneView, _ controller: WindowController, _ services: AppServices) -> Bool {
        selected(controller).map { services.agentTabs.existingView($0) === page } ?? false
    }

    /// The app after one New Workspace key, with no made-ahead workspace after it. `firstPageUsed`: the app's own
    /// first New Tab page counts as one that the person used. `second`: one more New Workspace key after it, so the
    /// window shows a workspace that it did not make ahead (its content is made at that key), on the page view of
    /// the tab that the key left.
    static func afterOneKey(_ install: String, firstPageUsed: Bool, second: Bool = false, _ body: (AppServices, Start) async throws -> Void) async throws {
        try await NewTabPageAtItsFrameTests.withAnEmptyPool(install, usedPages: false) { services, _, pane, _ in
            let tabs = services.agentTabs, store = services.daemon.store
            let controller = try #require(services.windows.active, "setup: no window")
            let first = try #require(pane.currentTabKey, "setup: the pane shows no tab")
            let firstWorkspace = try #require(controller.content?.workspace.id, "setup: the window shows no workspace")
            try #require(tabs.isNewTabPage(first), "setup: the app's first tab is no New Tab page")
            try await Moves.makesItsWorkspaceAhead(controller, services, row: install)
            let ahead = try #require(store.reservedWorkspace?.tabKey, "setup: the store has no made-ahead workspace")
            let page = try #require(tabs.existingView(ahead), "setup: the tab of the made-ahead workspace has no page view")
            if firstPageUsed { tabs.existingView(first)?.model.hostTouch.mark("the test's setup") }
            try #require(page.isUntouchedNewTab, "setup: the page view of the made-ahead workspace is no untouched New Tab page")
            // No workspace is made ahead from here on, until the row asks for it; the key takes the one that is there.
            store.reservationPaused = true
            defer { store.reservationPaused = false }
            var left = firstWorkspace
            for _ in 0..<(second ? 2 : 1) {
                let from = left
                try #require(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)), "setup: the New Workspace key was refused")
                await NewTabPageAtItsFrameTests.frame(services)
                try await PasswordManagerRouteTests.until({ controller.content.map { $0.workspace.id != from && $0.focusedPane != nil } == true },
                                                          within: .seconds(5), report: { "setup: the window shows no focused pane of the key's workspace" })
                await NewTabPageAtItsFrameTests.frame(services)
                left = try #require(controller.content?.workspace.id, "setup: the window shows no workspace after the key")
            }
            let shown = try #require(Self.selected(controller), "setup: no pane of the key's workspace has a selected tab")
            try #require(tabs.isNewTabPage(shown), "setup: the key's workspace does not show a New Tab page")
            try #require(tabs.existingView(shown) === page, "setup: the key's workspace does not show the page view that the window made ahead")
            try #require(controller.reservedContent.ready == nil, "setup: the window has a made-ahead workspace after the key, with the reservation paused")
            print("""
                NewTabIdlePageBySelectionTests: setup of \(install): after \(second ? 2 : 1) New Workspace key(s) the window shows \
                a New Tab tab with the page view that the window made ahead; the window made the shown workspace ahead: \
                \(!second); the surface ledger says that a pane draws that tab: \(Self.ledgerDraws(shown, services)); the app's \
                first page counts as used: \(firstPageUsed)
                """)
            try await body(services, Start(controller: controller, shown: shown, page: page, first: first, firstWorkspace: firstWorkspace, ahead: ahead))
            store.reservationPaused = false
            try await PasswordManagerRouteTests.until({ !store.workspaces.contains(where: \.isProvisional) },
                                                      report: { "the daemon did not answer each creation of the row" })
        }
    }

    /// Asks the window for its next workspace and waits until it is there.
    static func makesTheNextWorkspaceAhead(_ start: Start, _ services: AppServices) async throws {
        let store = services.daemon.store
        store.reservationPaused = false
        start.controller.reservedContent.fill()
        try await PasswordManagerRouteTests.until({ start.controller.reservedContent.ready != nil && store.reservedWorkspace.map { $0.tabKey != start.ahead } == true },
                                                  within: .seconds(10), report: { "setup: the window made no workspace ahead after the key" })
        store.reservationPaused = true
    }

    /// Row 1.
    @Test func aNewWorkspaceTakesNoPageViewOfATabThatTheWindowShows() async throws {
        try await Self.afterOneKey("cn-idle-by-selection-new", firstPageUsed: true, second: true) { services, start in
            let tabs = services.agentTabs, daemon = services.daemon
            let repair = services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)
            let made = try #require(tabs.showWorkspace(WorkspaceKey.generate(), name: "a workspace of the row", index: nil, cwd: nil, token: nil, on: daemon, repair: repair),
                                    "setup: the store shows no workspace before the daemon answers")
            let kept = tabs.existingView(start.shown) === start.page
            let took = tabs.existingView(made.tabKey) === start.page
            made.abandon()
            print("""
                NewTabIdlePageBySelectionTests: row 1, the store showed a new workspace: the tab that \
                the window shows kept its page view: \(kept); the new workspace's tab took that page view: \(took)
                """)
            #expect(kept && !took, "the tab that the window shows lost its page view to a new workspace of the store (the new workspace's tab took it: \(took))")
        }
    }

    /// Row 2.
    @Test func theWorkspaceMadeAheadTakesNoPageViewOfATabThatTheWindowShows() async throws {
        try await Self.afterOneKey("cn-idle-by-selection-reserve", firstPageUsed: true, second: true) { services, start in
            let tabs = services.agentTabs, daemon = services.daemon
            daemon.store.reservationPaused = false
            let made = tabs.reserveWorkspace(on: daemon, cwd: nil)
            daemon.store.reservationPaused = true
            let ahead = daemon.store.reservedWorkspace?.tabKey
            let kept = tabs.existingView(start.shown) === start.page
            let took = ahead.map { tabs.existingView($0) === start.page } ?? false
            tabs.releaseReservedWorkspace(on: daemon.store, .unshown)
            print("""
                NewTabIdlePageBySelectionTests: row 2, the store made the next workspace ahead (it made \
                one: \(made != nil)): the tab that the window shows kept its page view: \(kept); the made-ahead workspace's tab \
                took that page view: \(took)
                """)
            #expect(kept && !took, "the tab that the window shows lost its page view to the workspace made ahead (its tab took it: \(took))")
        }
    }

    /// Row 3.
    @Test func theWindowsIdleWorkTakesNoPageViewThatTheWindowShows() async throws {
        try await Self.afterOneKey("cn-idle-by-selection-ahead", firstPageUsed: true, second: true) { services, start in
            let tabs = services.agentTabs
            let before = Self.pages(services)
            try await Self.makesTheNextWorkspaceAhead(start, services)
            let ahead = services.daemon.store.reservedWorkspace?.tabKey
            let kept = Self.showsPage(start.page, start.controller, services)
            let took = ahead.map { tabs.existingView($0) === start.page } ?? false
            let built = Self.pages(services).filter { view in !before.contains { $0 === view } }.count
            print("""
                NewTabIdlePageBySelectionTests: row 3, the window made its next workspace ahead: the tab that the window shows \
                kept its page view: \(kept); the made-ahead workspace's tab has that page view: \(took); new page views: \(built)
                """)
            #expect(kept && !took, "the tab that the window shows lost its page view when the window made its next workspace ahead (the made-ahead workspace's tab has it: \(took))")
        }
    }

    /// Row 4, print only.
    @Test(arguments: [false, true]) func aWorkspaceThatGaveItsPageViewIsShownAgain(othersUsed: Bool) async throws {
        try await Self.afterOneKey("cn-idle-by-selection-again-\(othersUsed ? "used" : "idle")", firstPageUsed: false) { services, start in
            let tabs = services.agentTabs, controller = start.controller
            let own = tabs.existingView(start.first)
            try await Self.makesTheNextWorkspaceAhead(start, services)
            let ahead = services.daemon.store.reservedWorkspace?.tabKey
            let gave = tabs.existingView(start.first) == nil
            let toAhead = own != nil && (ahead.map { tabs.existingView($0) === own } ?? false)
            if othersUsed { start.page.model.hostTouch.mark("the test's setup") }
            let left = Self.showsPage(start.page, controller, services)
            let before = Self.pages(services)
            controller.state.showWorkspace(start.firstWorkspace)
            controller.showWorkspace(requested: controller.state.workspaceID)
            await NewTabPageAtItsFrameTests.frame(services)
            try await PasswordManagerRouteTests.until({ controller.content?.workspace.id == start.firstWorkspace && controller.content?.focusedPane != nil },
                                                      within: .seconds(5), report: { "setup: the window does not show the first workspace again" })
            await NewTabPageAtItsFrameTests.frame(services)
            let now = tabs.existingView(start.first)
            let built = Self.pages(services).filter { view in !before.contains { $0 === view } }.count
            print("""
                NewTabIdlePageBySelectionTests: row 4, a workspace that went out of view is shown again, the page of the workspace \
                that the window leaves counts as \(othersUsed ? "used" : "not touched") (the window showed that page before the \
                show: \(left)): before the show its New Tab tab had no page view: \(gave) (the made-ahead workspace's tab has it: \
                \(toAhead)); page views built at the show: \(built); after the show its tab has a page view: \(now != nil), the one \
                of the tab that the window showed before: \(now === start.page), its own one from before: \(now != nil && now === own)
                """)
        }
    }

    /// Row 5.
    @Test(arguments: [false, true]) func aNewWorkspaceKeyLeavesNoEmptyPaneAtACommit(madeAtItsKey: Bool) async throws {
        try await Self.afterOneKey("cn-idle-by-selection-leaves\(madeAtItsKey ? "-at-key" : "")", firstPageUsed: true, second: madeAtItsKey) { services, start in
            let controller = start.controller, tabs = services.agentTabs
            let left = try #require(controller.content, "setup: the window shows no workspace")
            let pane = try #require(left.focusedPane, "setup: the window's workspace has no focused pane")
            try #require(pane.view.hostsContent, "setup: the pane that the window shows has no content before the key")
            let page = start.page, drawn = Self.ledgerDraws(start.shown, services)
            let before = Self.pages(services)
            let commits = Commits()
            // After Core Animation's commit of each turn, from the key on: what that commit had.
            let sampler = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: CommitBoundary.order,
                                              drawsNothingAfterCommit: true) { [weak controller, weak left, weak pane] _ in
                guard commits.counts, let controller, let left, let pane else { return }
                commits.all += 1
                if controller.content === left, !pane.view.hostsContent { commits.withAnEmptyPane += 1 }
            }
            defer { sampler.invalidate() }
            commits.counts = true
            try #require(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)), "setup: the New Workspace key was refused")
            let inTheKeysCall = !pane.view.hostsContent
            // At the return of the key's call: is the left workspace still the window's content with the tab selected, and has that tab its page view.
            let stillShown = controller.content === left && Self.selected(controller) == start.shown
            let keptAtTheReturn = tabs.existingView(start.shown) === page
            await NewTabPageAtItsFrameTests.frame(services)
            try await PasswordManagerRouteTests.until({ controller.content.map { $0 !== left && $0.focusedPane != nil } == true },
                                                      within: .seconds(5), report: { "setup: the window shows no focused pane of the key's workspace" })
            await NewTabPageAtItsFrameTests.frame(services)
            // The run loop can pass the key, the swap and both frames with no rest: the row waits for one commit at least.
            _ = try? await PasswordManagerRouteTests.until({ commits.all > 0 }, within: .seconds(5), report: { "no commit of the run loop" })
            commits.counts = false
            let took = Self.showsPage(page, controller, services)
            let built = Self.pages(services).filter { view in !before.contains { $0 === view } }.count
            print("""
                NewTabIdlePageBySelectionTests: row 5 (the window made the left workspace's content at its key: \(madeAtItsKey)), \
                one more New Workspace key with no workspace made ahead and no page in the \
                pool; before the key the surface ledger said that a pane draws the tab that the key leaves: \(drawn); when the \
                key's call returned the window still showed the left workspace with that tab selected: \(stillShown), and that \
                tab had its page view: \(keptAtTheReturn); the tab of \
                the key's workspace has the page view of the tab that the key left: \(took); page views built: \(built); the left \
                pane was empty when the key's call returned: \(inTheKeysCall); commits of the run loop from the key on: \
                \(commits.all), of them with the left workspace in the window and its pane empty: \(commits.withAnEmptyPane)
                """)
            #expect(commits.all > 0, "the row saw no commit of the run loop in 5 s after the key")
            #expect(!stillShown || keptAtTheReturn, "when the New Workspace key's call returned, the window still showed the left workspace, and the tab that its pane has selected had lost its page view")
            #expect(!inTheKeysCall, "the New Workspace key took the page view out of the pane that it leaves before the window's swap")
            #expect(commits.withAnEmptyPane == 0, "\(commits.withAnEmptyPane) of \(commits.all) commits after the key had the left workspace in the window with an empty pane")
        }
    }
}

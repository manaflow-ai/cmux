import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Which New Tab page view is idle (`AgentTabStore.idlePage`): never the page view of a tab that a pane of a workspace
/// which a window shows has selected, except the tab that a key leaves. The surface ledger does not decide it: a
/// pane is `visible` in the ledger only after a layout pass of its workspace's view, so a tab that the window shows
/// can be `not drawn` there.
///
/// Each row starts after one New Workspace key: the window shows that key's workspace on a New Tab page that the
/// person did not touch, with the page view that the window made ahead. The window makes no workspace ahead in the
/// row until the row asks for it (the store's pause of the reservation, as under memory pressure).
///
/// - Row 1: the window makes its next workspace ahead (idle work). Want: the tab that the window shows keeps its
///   page view.
/// - Row 2: the store shows a new workspace for a key that leaves no workspace (the store's own call, no window).
///   Want: the tab that the window shows keeps its page view, and the new workspace's tab does not have it.
/// - Row 3, print only: a workspace that went out of view gave its page view to the workspace that the window made
///   ahead, and is shown again. How many page views are built at that show, with an untouched page in another
///   workspace that is out of view, and with none.
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

    /// The tab that the strip of the window's focused pane has selected.
    static func selected(_ controller: WindowController) -> String? {
        controller.content?.focusedPane?.stripModel.selectedID?.rawValue
    }

    /// Whether the surface ledger says that a pane draws tab `key` now.
    static func ledgerDraws(_ key: String, _ services: AppServices) -> Bool {
        services.cache.isRendering(key) || services.cache.isRendering(services.agentTabs.resolve(key))
    }

    /// The page views of New Tab pages that the store has now.
    static func pages(_ services: AppServices) -> [AgentPaneView] {
        services.agentTabs.views.values.filter { $0.model.newTab != nil }
    }

    /// The app after one New Workspace key, with no made-ahead workspace after it. `firstPageUsed`: the app's own
    /// first New Tab page counts as one that the person used.
    static func afterOneKey(_ install: String, firstPageUsed: Bool, _ body: (AppServices, Start) async throws -> Void) async throws {
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
            let before = Set(store.workspaces.map(\.id))
            try #require(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)), "setup: the New Workspace key was refused")
            await NewTabPageAtItsFrameTests.frame(services)
            let made = try #require(store.workspaces.first { !before.contains($0.id) }?.id, "setup: the New Workspace key made no workspace in its turn")
            try await PasswordManagerRouteTests.until({ controller.content?.workspace.id == made && controller.content?.focusedPane != nil },
                                                      within: .seconds(5), report: { "setup: the window shows no focused pane of the key's workspace" })
            await NewTabPageAtItsFrameTests.frame(services)
            let shown = try #require(Self.selected(controller), "setup: the focused pane of the key's workspace has no selected tab")
            try #require(tabs.isNewTabPage(shown), "setup: the key's workspace does not show a New Tab page")
            try #require(tabs.existingView(shown) === page, "setup: the key's workspace does not show the page view that the window made ahead")
            try #require(controller.reservedContent.ready == nil, "setup: the window has a made-ahead workspace after the key, with the reservation paused")
            print("""
                NewTabIdlePageBySelectionTests: setup of \(install): after the key the window shows a New Tab tab with the page \
                view that the window made ahead; the surface ledger says that a pane draws that tab: \
                \(Self.ledgerDraws(shown, services)); the app's first page counts as used: \(firstPageUsed)
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
    @Test func theWorkspaceMadeAheadTakesNoPageViewThatTheWindowShows() async throws {
        try await Self.afterOneKey("cn-idle-by-selection-ahead", firstPageUsed: true) { services, start in
            let tabs = services.agentTabs
            let before = Self.pages(services)
            try await Self.makesTheNextWorkspaceAhead(start, services)
            let ahead = services.daemon.store.reservedWorkspace?.tabKey
            let kept = tabs.existingView(start.shown) === start.page
            let took = ahead.map { tabs.existingView($0) === start.page } ?? false
            let built = Self.pages(services).filter { view in !before.contains { $0 === view } }.count
            print("""
                NewTabIdlePageBySelectionTests: row 1, the window made its next workspace ahead: the tab that the window shows \
                kept its page view: \(kept); the made-ahead workspace's tab has that page view: \(took); new page views: \
                \(built); the surface ledger says that a pane draws the shown tab: \(Self.ledgerDraws(start.shown, services))
                """)
            #expect(kept, "the tab that the window shows lost its page view when the window made its next workspace ahead (the made-ahead workspace's tab has it: \(took))")
        }
    }

    /// Row 2.
    @Test func aNewWorkspaceTakesNoPageViewOfATabThatItsKeyDoesNotLeave() async throws {
        try await Self.afterOneKey("cn-idle-by-selection-new", firstPageUsed: true) { services, start in
            let tabs = services.agentTabs, daemon = services.daemon
            let repair = services.machines.emptyWorkspaceRepair(daemon.machineID, local: services.emptyWorkspaces)
            let made = try #require(tabs.showWorkspace(WorkspaceKey.generate(), name: "a workspace of the row", index: nil, cwd: nil, token: nil, on: daemon, repair: repair),
                                    "setup: the store shows no workspace before the daemon answers")
            let kept = tabs.existingView(start.shown) === start.page
            let took = tabs.existingView(made.tabKey) === start.page
            made.abandon()
            print("""
                NewTabIdlePageBySelectionTests: row 2, the store showed a new workspace for a key that leaves no workspace: the \
                tab that the window shows kept its page view: \(kept); the new workspace's tab took that page view: \(took)
                """)
            #expect(kept && !took, "the tab that the window shows lost its page view to a new workspace whose key did not leave it (the new workspace's tab took it: \(took))")
        }
    }

    /// Row 3, print only.
    @Test(arguments: [false, true]) func aWorkspaceThatGaveItsPageViewIsShownAgain(othersUsed: Bool) async throws {
        try await Self.afterOneKey("cn-idle-by-selection-again-\(othersUsed ? "used" : "idle")", firstPageUsed: false) { services, start in
            let tabs = services.agentTabs, controller = start.controller
            let own = tabs.existingView(start.first)
            try await Self.makesTheNextWorkspaceAhead(start, services)
            let ahead = services.daemon.store.reservedWorkspace?.tabKey
            let gave = tabs.existingView(start.first) == nil
            let toAhead = own != nil && (ahead.map { tabs.existingView($0) === own } ?? false)
            if othersUsed { tabs.existingView(start.shown)?.model.hostTouch.mark("the test's setup") }
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
                NewTabIdlePageBySelectionTests: row 3, a workspace that went out of view is shown again, the page of the workspace \
                that the window leaves counts as \(othersUsed ? "used" : "not touched"): before the show its New Tab tab had no \
                page view: \(gave) (the made-ahead workspace's tab has it: \(toAhead)); page views built at the show: \(built); \
                after the show its tab has a page view: \(now != nil), the one of the tab that the window showed before: \
                \(now === start.page)
                """)
        }
    }
}

import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The New Tab tabs that a store restored (a quit and a reopen of the app with New Tab tabs open): chat tabs of
/// this Mac with no chat. The store makes such a tab a New Tab page when it first asks for the tab's view
/// (`AgentTabStore.view(for:)`), and a pane asks for a tab's view only when it shows the tab. So after a reopen the
/// page views are those of the New Tab tabs that a pane shows, not one for each tab.
///
/// Row 11 of the rows of `NewTabHoldMovesItsPageTests`: the person goes over 4 restored New Tab tabs of one pane,
/// one tab at each frame. Each of these pages is one that the person did not touch, and they draw one screen. Want:
/// at the open the store has a page view only for a tab that the pane shows; the walk makes one page view at most
/// (the first tab's, when the pane showed no New Tab tab before); the tabs have one page view at one time at most;
/// and the tab that the pane shows has a page view at each step, with that tab's own folder and token.
///
/// A whole window with no daemon: one workspace with one pane of 1 terminal tab and 4 chat tabs with no chat, as
/// `LargeSessionWindowFixture` makes its window. The pool of pages made ahead is empty, so each new page view is
/// a cold one. No page loads (an inert address). A frame is the app's own: the row waits for one by an event. Each
/// tab switch is the pane's own call (`select`).
///
/// Limits. Each page view is a WebKit one. The row reads the count of page views and which view a tab has; it does
/// not read what a page draws.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(3)))
struct NewTabPagesOfRestoredTabsTests {
    static let install = "new-tab-pages-of-restored-tabs"
    static let workspace = "restored-ws-1"

    /// One workspace with one pane: a terminal tab, then 4 chat tabs of this Mac with no chat.
    static func tree() -> DaemonTree {
        var tabs = [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "zsh")]
        for index in 2...5 {
            var chat = TabSnapshot(surface: SurfaceID(rawValue: UInt64(index)), kind: .conversation, title: "chat", browserRenderer: "frontend")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: AgentSessionRef.host(installID: install), session: nil, harness: nil))
            tabs.append(chat)
        }
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: LayoutNode.leaf(pane.id), panes: [pane])
        let snapshot = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: workspace), name: "workspace 1", screens: [screen])
        var tree = DaemonTree(registryID: "s-local", workspaces: [snapshot])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: workspace), index: 0)])
        return tree
    }

    /// Runs `body` on a whole window of `tree()`, with an empty pool of pages made ahead, then closes it.
    static func withWindow(_ body: @MainActor (AppServices, PaneController) async throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]),
                                   agentPaneEnvironment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"])
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        // Before the window opens: a tab that the pane shows at the open is this Mac's, and no page is made ahead.
        let tabs = services.agentTabs, pool = services.newTabSpares
        tabs.localHost = AgentSessionRef.host(installID: install)
        pool.dropAll()
        pool.makeSpare = { _ in nil }
        defer { pool.makeSpare = nil }
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: [workspace], frame: CGRect(x: 200, y: 200, width: 1600, height: 900)))
        defer { controller.teardown(); controller.window?.close() }
        for _ in 0..<50 where controller.workspaceContent == nil { await LargeSessionWindowFixture.drainMain() }
        let content = try #require(controller.workspaceContent, "setup: the window shows no workspace")
        content.contentView.layoutSubtreeIfNeeded()
        await LargeSessionWindowFixture.drainMain()
        try #require(tabs.canHostChat, "setup: this build has no New Tab page")
        let pane = try #require(controller.focusedPane, "setup: the window has no focused pane")
        try await body(services, pane)
    }

    /// Row 11 (see the suite's text).
    @Test func aWalkOverRestoredNewTabTabsMakesOnePageViewAtMost() async throws {
        try await Self.withWindow { services, pane in
            let tabs = services.agentTabs
            let chats = pane.pane.tabs.filter { $0.kind == .conversation }.map(\.id)
            try #require(chats.count == 4, "setup: the pane has \(chats.count) chat tabs, want 4")
            let views = NewTabHoldMovesItsPageTests.Views()
            // The page views that the store has now.
            @MainActor func read() -> Int {
                let now = tabs.views.values
                now.forEach(views.note)
                return now.count
            }
            let shownAtTheOpen = pane.currentTabKey.map { chats.contains($0) } == true ? 1 : 0
            let atTheOpen = read()
            var most = atTheOpen, steps = 0, noNewTabPage = 0, withNoPage = 0, notItsOwn = 0
            for key in chats {
                let id = try #require(pane.orderedIDs.first { $0.rawValue == key }, "setup: the chat tab \(key) is not in the strip")
                pane.select(id)
                await NewTabPageAtItsFrameTests.frame(services)
                try #require(pane.currentTabKey == key, "setup: the pane does not show the tab that the row selected, one frame after the select")
                steps += 1
                if !tabs.isNewTabPage(key) { noNewTabPage += 1 }
                if tabs.existingView(key) == nil { withNoPage += 1 } else if !NewTabHoldOtherScreensTests.hasItsOwnContext(key, tabs) { notItsOwn += 1 }
                most = max(most, read())
            }
            print("""
                NewTabPagesOfRestoredTabsTests: row 11, a walk over \(steps) restored New Tab tabs of one pane: the store had \
                \(atTheOpen) page views at the open (\(shownAtTheOpen) of the 4 tabs shown then), \(views.count) page views over the \
                walk, \(most) at one time at most; \(noNewTabPage) of the shown tabs were no New Tab page, \(withNoPage) had no \
                page view, \(notItsOwn) had a page view with another tab's folder or token
                """)
            #expect(atTheOpen == shownAtTheOpen, "the store has \(atTheOpen) page views at the open, and the pane shows \(shownAtTheOpen) of the restored New Tab tabs: want a page view only for a tab that a pane shows")
            #expect(noNewTabPage == 0, "\(noNewTabPage) of \(steps) restored tabs were no New Tab page when the pane showed them")
            #expect(withNoPage == 0, "\(withNoPage) of \(steps) steps showed a tab with no page view, one frame after the pane showed it")
            #expect(notItsOwn == 0, "\(notItsOwn) of \(steps) steps showed a page view with another tab's folder or token")
            #expect(views.count <= 1, "\(views.count) page views were made over the open and the walk, want 1 at most")
            #expect(most <= 1, "the restored New Tab tabs had \(most) page views at one time, want 1 at most")
        }
    }
}

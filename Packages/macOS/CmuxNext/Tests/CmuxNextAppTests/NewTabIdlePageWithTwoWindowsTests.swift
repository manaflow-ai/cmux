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

/// A New Tab key in a pane of a workspace that 2 windows show (two windows on one space). A tab that is no terminal
/// has ONE view: the window that showed it first draws it, and the same pane of the other window shows a notice with
/// Show Here (`PaneController+SharedSpace.swift`). The page view of such a tab is no idle page (`AgentTabStore.idlePage`)
/// for the pane that leaves it: the other window draws the tab or has it selected.
///
/// Each row starts after one New Workspace key: the first window shows that key's workspace on a New Tab page that
/// the person did not touch. Then a second window opens as a view of the same space (Open Space in New Window) and
/// shows the same workspace, with the same tab selected in the same pane. The pool of pages made ahead is empty.
///
/// - Row 1: the SECOND window draws the tab (Show Here there), the first window shows the notice. A New Tab key in the
///   first window. Want: no page view is made in the key's turn (the frame rule: one new page at a frame), the second
///   window's pane keeps the tab's page view as its content, and the new tab has a page view of its own after a frame.
/// - Row 2: the FIRST window draws the tab, the second window shows the notice. A New Tab key in the first window.
///   Want: no page view is made in the key's turn, the second window's pane draws the tab's page view after the
///   key (the first window stopped drawing it), and the new tab has a page view of its own after a frame.
///
/// Limits. Each page view is a WebKit one (the package's tests have no Chromium host), no window is on a display,
/// and the rows read which view a tab has and which window it is in, not what a page draws.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabIdlePageWithTwoWindowsTests {
    typealias Selection = NewTabIdlePageBySelectionTests

    /// What a row starts with: the first window's pane, the same pane of the second window, the tab that both have
    /// selected (by the name that the first window's pane has for it) and that tab's page view.
    struct Two {
        let pane: PaneController
        let other: PaneController
        let tab: String
        let page: AgentPaneView
    }

    /// Whether `pane` has tab `tab` selected and shown (the tab itself or its notice), by each name of the tab.
    static func shows(_ tab: String, _ pane: PaneController, _ services: AppServices) -> Bool {
        pane.currentTabKey.map { services.agentTabs.resolve($0) } == services.agentTabs.resolve(tab)
    }

    /// The setup of each row. `otherDraws`: the second window takes the tab's view (Show Here), so the first window
    /// shows the notice.
    static func twoWindows(_ install: String, otherDraws: Bool, _ body: (AppServices, Two) async throws -> Void) async throws {
        try await Selection.afterOneKey(install, firstPageUsed: true) { services, start in
            let tabs = services.agentTabs, windows = services.windows, here = start.controller
            try await PasswordManagerRouteTests.until({ !services.daemon.store.workspaces.contains(where: \.isProvisional) },
                                                      report: { "setup: the daemon did not answer the creation of the key's workspace" })
            await NewTabPageAtItsFrameTests.frame(services)
            let workspace = try #require(here.content?.workspace.id, "setup: the first window shows no workspace")
            let pane = try #require(here.content?.focusedPane, "setup: the first window has no focused pane")
            let tab = try #require(pane.currentTabKey, "setup: the first window's pane shows no tab")
            try #require(tabs.existingView(tab) === start.page, "setup: the first window's pane does not show the page view of the key's workspace")
            let listed = windows.sharedWorkspaces(in: here.state.profileID, for: "the second window of the row", registry: windows.registry.value)
            try #require(listed.contains(workspace), """
                setup: a second window on the first window's space would not list the workspace that the first window shows \
                (it would list \(listed.count) workspaces; the home session's spaces are loaded: \(WindowProfiles.membership(services.machines) != nil))
                """)
            let there = try #require(windows.openView(id: UUID().uuidString.lowercased(), of: here.state.profileID),
                                     "setup: no second window opened as a view of the first window's space")
            if there.content?.workspace.id != workspace { windows.show(workspaceID: workspace, inWindow: there.state.id) }
            try await PasswordManagerRouteTests.until({ there.content?.workspace.id == workspace && there.content?.paneController(key: pane.paneKey) != nil },
                                                      within: .seconds(10),
                                                      report: { "setup: the second window does not show the first window's workspace with its pane (it shows a workspace: \(there.content != nil))" })
            await NewTabPageAtItsFrameTests.frame(services)
            try #require(here.content?.workspace.id == workspace && here.content?.focusedPane === pane, "setup: the first window does not show its workspace and pane after the second window opened")
            let other = try #require(there.content?.paneController(key: pane.paneKey), "setup: the second window has no such pane")
            try #require(other !== pane, "setup: the 2 windows have one pane object")
            let id = try #require(other.orderedIDs.first { tabs.resolve($0.rawValue) == tabs.resolve(tab) }, "setup: the second window's pane does not list the tab")
            other.select(id)
            await NewTabPageAtItsFrameTests.frame(services)
            try #require(Self.shows(tab, other, services), "setup: the second window's pane does not show the tab one frame after its select")
            try #require(other.elsewhereNotice?.key == other.currentTabKey && pane.elsewhereNotice == nil && pane.view.hostsContent && start.page.window === pane.view.window, """
                setup: with the tab selected in both windows, the first window does not draw it or the second window does not show the notice \
                (the second window shows the notice: \(other.elsewhereNotice != nil), the first: \(pane.elsewhereNotice != nil))
                """)
            if otherDraws {
                other.showHere(id.rawValue)
                await NewTabPageAtItsFrameTests.frame(services)
                try #require(other.elsewhereNotice == nil && other.view.hostsContent && start.page.window === other.view.window && pane.elsewhereNotice?.key == pane.currentTabKey, """
                    setup: after Show Here in the second window, that window does not draw the tab or the first window does not show the notice \
                    (the second window shows the notice: \(other.elsewhereNotice != nil), the first: \(pane.elsewhereNotice != nil))
                    """)
            }
            try #require(Self.shows(tab, pane, services) && tabs.existingView(tab) === start.page && start.page.isUntouchedNewTab,
                         "setup: the tab has no untouched New Tab page view before the row's key, or the first window's pane does not have it selected")
            try await body(services, Two(pane: pane, other: other, tab: tab, page: start.page))
        }
    }

    /// One New Tab key in the first window's pane, then 2 frames. The checks that both rows have.
    static func aNewTabKey(_ two: Two, _ services: AppServices, row: String) async throws {
        let tabs = services.agentTabs, pane = two.pane, other = two.other
        let before = Selection.pages(services)
        let made = { Selection.pages(services).filter { view in !before.contains { $0 === view } }.count }
        NewTabPage.open(in: pane, seed: nil)
        let inTheTurn = made()
        let keptInTheTurn = tabs.existingView(two.tab) === two.page
        await NewTabPageAtItsFrameTests.frame(services)
        await NewTabPageAtItsFrameTests.frame(services)
        let new = try #require(pane.currentTabKey, "setup: the first window's pane shows no tab after the New Tab key")
        try #require(!Self.shows(two.tab, pane, services) && tabs.isNewTabPage(new), "setup: the first window's pane does not show a new New Tab tab after the key")
        let own = tabs.existingView(new)
        let kept = tabs.existingView(two.tab) === two.page
        let drawsThere = Self.shows(two.tab, other, services) && other.elsewhereNotice == nil && other.view.hostsContent && two.page.window === other.view.window
        print("""
            NewTabIdlePageWithTwoWindowsTests: \(row): page views made in the turn of the New Tab key: \(inTheTurn), after 2 \
            frames: \(made()); the tab that the 2 windows had selected kept its page view at the return of the key's call: \
            \(keptInTheTurn), after 2 frames: \(kept); the second window's pane draws that tab's page view after 2 frames: \
            \(drawsThere) (it shows the notice: \(other.elsewhereNotice != nil)); the new tab has a page view: \(own != nil), \
            the one of the tab that the 2 windows had selected: \(own === two.page)
            """)
        #expect(inTheTurn == 0, "\(inTheTurn) page view(s) made in the turn of a New Tab key, in a pane whose tab the other window of the workspace also has selected")
        #expect(keptInTheTurn && kept, "the tab that the other window has selected lost its page view to the New Tab key of this window")
        #expect(drawsThere, "the second window's pane does not draw the page view of its selected tab after the New Tab key of the first window")
        #expect(own != nil && own !== two.page, "the new tab has no page view of its own 2 frames after its key")
    }

    /// Row 1.
    @Test func aNewTabKeyTakesNoPageViewThatTheOtherWindowDraws() async throws {
        try await Self.twoWindows("cn-idle-two-windows-other-draws", otherDraws: true) { services, two in
            try await Self.aNewTabKey(two, services, row: "row 1, the second window draws the tab")
        }
    }

    /// Row 2.
    @Test func aNewTabKeyMakesNoPageInItsTurnWhenTheOtherWindowHasTheTabSelected() async throws {
        try await Self.twoWindows("cn-idle-two-windows-this-draws", otherDraws: false) { services, two in
            try await Self.aNewTabKey(two, services, row: "row 2, the first window draws the tab")
        }
    }
}

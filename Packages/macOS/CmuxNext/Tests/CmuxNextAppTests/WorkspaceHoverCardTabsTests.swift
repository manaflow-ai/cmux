import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-21 (u9696): the workspace hover card lists every tab open in the workspace,
/// in pane and tab order, grouped by pane when there is more than one, each with its status
/// (OSC 7501, the tab bar's dot and unread state) and a useful second line (the program's status
/// text, the folder, a page's host, a chat's agent). A click on a row selects that tab. The list
/// reads the row's cached tabs (`SidebarWorkspace.tabs`, mapped when the daemon's records change):
/// a hover maps nothing.
@MainActor
struct WorkspaceHoverCardTabsTests {
    /// Two panes: a terminal whose program waits for approval (an OSC 7501 `blocked` record) and a
    /// quiet terminal in a folder, then a browser page.
    func store() throws -> DaemonStore {
        let store = DaemonStore()
        let first = PaneSnapshot(id: 1, tabs: [
            TabSnapshot(surface: 1, terminalResourceID: "term_1", title: "claude", cwd: "/Users/someone/fun/cmux"),
            TabSnapshot(surface: 2, terminalResourceID: "term_2", title: "zsh", cwd: "/Users/someone/fun/site"),
        ])
        let second = PaneSnapshot(id: 2, tabs: [
            TabSnapshot(surface: 3, kind: .browser, title: "Pull requests", url: "https://www.github.com/manaflow-ai/cmux/pulls"),
        ])
        let screen = ScreenSnapshot(id: 1, layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2)), panes: [first, second])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "skibidi", screens: [screen])]))
        let blocked = #"{"program_status":[{"id":"","state":"blocked","app":"claude","title":"Approve edit to main.rs","updated_seq":"1"}]}"#
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_1","extra":\#(blocked)},{"id":"term_2","extra":{}}],"extra":{"state":{}}}}}"#
        let item = try #require(SessionStreamItem.decode(Data(line.utf8)))
        store.session.apply(item, in: store)
        return store
    }

    func row() throws -> SidebarWorkspace {
        let workspace = try #require(try store().workspaces.first)
        return SidebarMapping.shared.row(workspace, machine: .local)
    }

    /// The row carries each tab's pane, status and second line, mapped once with the row.
    @Test func theRowCarriesEachTabsPaneStatusAndDetail() throws {
        let tabs = try row().tabs
        #expect(tabs.map(\.pane) == [0, 0, 1])
        #expect(tabs[0].state == .waiting(kind: nil))
        #expect(tabs[0].detail == "claude: Approve edit to main.rs")
        #expect(tabs[1].state == .idle)
        #expect(tabs[1].detail?.hasSuffix("fun/site") == true)
        #expect(tabs[2].detail == "github.com")
    }

    /// Two panes: a header per pane, then its tabs, each with its second line.
    @Test func theCardListsTabsGroupedByPane() throws {
        let card = WorkspaceHoverCardView()
        card.configure(.make(try row(), machine: nil, now: Date()))
        let lines = card.tabLines
        #expect(lines.count == 5)
        #expect(lines[0] == Strings.paneHeader(1))
        #expect(lines[1].hasPrefix("claude"))
        #expect(lines[1].contains("Approve edit to main.rs"))
        #expect(lines[3] == Strings.paneHeader(2))
        #expect(lines[4].contains("github.com"))
    }

    /// One pane draws no header; past the cap the card says how many more.
    @Test func manyTabsCapWithAMoreRow() {
        let tabs = (0..<20).map { SidebarTab(id: TabID("t\($0)"), title: "tab \($0)", detail: "~/src/\($0)") }
        let workspace = SidebarWorkspace(id: WorkspaceID("w"), title: "many", tabs: tabs)
        let card = WorkspaceHoverCardView()
        card.configure(.make(workspace, machine: nil, now: Date()))
        let lines = card.tabLines
        #expect(lines.count == WorkspaceHoverCardView.visibleTabLimit + 1)
        #expect(lines.first?.hasPrefix("tab 0") == true)
        #expect(lines.last == Strings.statusMore(20 - WorkspaceHoverCardView.visibleTabLimit))
    }

    /// A workspace with one tab is that tab: the card already says what it is.
    @Test func oneTabListsNoTabs() {
        let workspace = SidebarWorkspace(id: WorkspaceID("w"), title: "one", tabs: [SidebarTab(id: TabID("t"), title: "zsh")])
        let card = WorkspaceHoverCardView()
        card.configure(.make(workspace, machine: nil, now: Date()))
        #expect(card.tabLines.isEmpty)
    }

    /// A click on a tab's row selects that tab; a click elsewhere on the card selects none.
    @Test func clickingATabRowSelectsIt() throws {
        let card = WorkspaceHoverCardView()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = card
        card.configure(.make(try row(), machine: nil, now: Date()))
        window.layoutIfNeeded()
        var selected: [TabID] = []
        card.onSelectTab = { selected.append($0) }
        let frame = try #require(card.tabRowFrameOnScreen(at: 2))
        #expect(card.hoverCardClick(atScreen: CGPoint(x: frame.midX, y: frame.midY)))
        #expect(selected == [try row().tabs[2].id])
        let title = window.convertToScreen(NSRect(x: 0, y: card.bounds.maxY - 2, width: 4, height: 1))
        #expect(!card.hoverCardClick(atScreen: CGPoint(x: title.midX, y: title.midY)))
        #expect(selected.count == 1)
    }

    /// Showing the card again for the same workspace makes no new row views (the pool is reused).
    @Test func rowViewsAreReusedCardToCard() throws {
        let card = WorkspaceHoverCardView()
        let content = WorkspaceHoverCardContent.make(try row(), machine: nil, now: Date())
        card.configure(content)
        let made = card.tabRowViewsMade
        for _ in 0..<10 { card.configure(content) }
        #expect(card.tabRowViewsMade == made)
    }
}

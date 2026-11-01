import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextLayout
@testable import CmuxNextApp
import Testing

/// Leo 2026-10-30, of an agent chat that opened a chat (and links) beside a page already open on its right:
/// "stupid animation to open up a tab in the main pane THEN opening up a right pane and animating that + stupid
/// to not reuse the existing opened fucking right pane", and "IT'S THE FUCKING SINGLE MAIN TO OTHER FUCKING".
/// What a chat opens goes to the column already on its right, never a new pane beside it: since #28989 (Leo's
/// "go split instead of just adding a third column") that is RightColumnPlacement's split below or lower pane.
struct ChatLinkReusesRightPaneTests {
    private static let chatDock = DockColumn(edge: .left, role: .agentChat)

    /// The pane on the right is found by column order when no drawn frame shows it (a right dock, a scrolled column).
    @Test func thePaneOnTheRightIsFoundByColumnOrder() {
        #expect(LinkOpenPlacement<String>.paneRight(of: "chat", columns: [["chat"], ["page"]], takesTabs: { _ in true }, recency: []) == "page")
        #expect(LinkOpenPlacement<String>.paneRight(of: "chat", columns: [["chat"]], takesTabs: { _ in true }, recency: []) == nil)
        #expect(LinkOpenPlacement<String>(setting: .splitRight).target(source: "chat", takesTabs: true, right: "page") == .pane("page"))
    }

    /// Leo 2026-10-30: "IF I'M FOCUSED ON THE MAIN PANE OPEN IT THERE". Cmd-T in the chat dock opens the New Tab
    /// page in the dock; a chat or any other new tab from it still goes to the strip.
    @Test func cmdTInTheMainPaneOpensThePageThere() {
        let columns = [LayoutColumn(id: "dock", root: .leaf("chat"), dock: Self.chatDock), LayoutColumn(id: "right", root: .leaf("page"))]
        #expect(ChatColumnPlacement.keepsNewTabPage(from: "chat", columns: columns))
        #expect(ChatColumnPlacement.resolve(from: "chat", columns: columns) { _ in false } == .tab(in: "page"))
    }

    /// "IF IM NOT THEN OPEN IT FUCKING IN THAT OTHER PLACE": with another pane focused, Cmd-T opens in that pane.
    @Test func cmdTInAnotherPaneOpensThere() {
        let columns = [LayoutColumn(id: "dock", root: .leaf("chat"), dock: Self.chatDock), LayoutColumn(id: "right", root: .leaf("page"))]
        #expect(!ChatColumnPlacement.keepsNewTabPage(from: "page", columns: columns))
        #expect(ChatColumnPlacement.resolve(from: "page", columns: columns) { _ in false } == .here)
    }

    /// Home's pinned dock keeps its own route, and a pane in no dock is no chat dock.
    @Test func homesPinnedDockAndPlainPanesKeepTheirRoute() {
        let home = [LayoutColumn(id: "dock", root: .leaf("home"), dock: DockColumn(edge: .left, role: .agentChat, isPinned: true)),
                    LayoutColumn(id: "right", root: .leaf("page"))]
        #expect(!ChatColumnPlacement.keepsNewTabPage(from: "home", columns: home))
        #expect(!ChatColumnPlacement.keepsNewTabPage(from: "chat", columns: [LayoutColumn(id: "chat", root: .leaf("chat"))]))
        let plain = [LayoutColumn(id: "dock", root: .leaf("files"), dock: DockColumn(edge: .left)), LayoutColumn(id: "right", root: .leaf("page"))]
        #expect(!ChatColumnPlacement.keepsNewTabPage(from: "files", columns: plain))
    }

    /// "not to fucking open it up in the main fucking pane": a terminal or browser picked on a page in the chat dock
    /// opens in the strip beside it, the pane used last first. The rule reads the layout, not the dock's tabs, so a
    /// page left alone in the dock (its chat closed) still sends its pick to the strip (review of #28544 at a6f8b21a).
    @Test func aPickOnAPageInTheChatDockOpensInTheStrip() {
        let columns = [LayoutColumn(id: "dock", root: .leaf("chat"), dock: Self.chatDock),
                       LayoutColumn(id: "right", root: .leaf("page")), LayoutColumn(id: "more", root: .leaf("other"))]
        #expect(ChatColumnPlacement.pagePick(from: "chat", columns: columns) == "page")
        #expect(ChatColumnPlacement.pagePick(from: "chat", columns: columns, recent: ["chat", "other"]) == "other")
        #expect(ChatColumnPlacement.pagePick(from: "chat", columns: columns, zoomed: true) == nil, "a zoomed screen shows the dock alone")
        #expect(ChatColumnPlacement.pagePick(from: "page", columns: columns) == nil, "a page in the strip is replaced in place")
        let home = [LayoutColumn(id: "dock", root: .leaf("home"), dock: DockColumn(edge: .left, role: .agentChat, isPinned: true)),
                    LayoutColumn(id: "right", root: .leaf("page"))]
        #expect(ChatColumnPlacement.pagePick(from: "home", columns: home) == nil)
    }

    /// #29848: a pane Split Down made below the chat in the dock is an ordinary pane: a New Tab page there (Split
    /// Down from a chat opens one) takes its pick in place, not in the strip; the chat's own pane keeps its route.
    @Test func aPickOnAPageBelowTheChatInTheDockTakesThePagesPlace() {
        let columns = [LayoutColumn(id: "dock", root: .split("s", axis: .vertical, ratio: 0.5, a: .leaf("chat"), b: .leaf("below")),
                                    dock: Self.chatDock),
                       LayoutColumn(id: "right", root: .leaf("page"))]
        #expect(ChatColumnPlacement.keepsNewTabPage(from: "chat", columns: columns))
        #expect(ChatColumnPlacement.pagePick(from: "chat", columns: columns) == "page")
        #expect(!ChatColumnPlacement.keepsNewTabPage(from: "below", columns: columns))
        #expect(ChatColumnPlacement.pagePick(from: "below", columns: columns) == nil, "a page below the chat is replaced in place")
        // A browser typed on that page opens there too (review of #29848: it went through the dock's strip route).
        #expect(ChatColumnPlacement.isBelowChat("below", columns: columns))
        #expect(!ChatColumnPlacement.isBelowChat("chat", columns: columns), "the chat's own picks still go beside it")
        #expect(!ChatColumnPlacement.isBelowChat("page", columns: columns))
    }

    /// #29848: Split Down grows an unpinned chat dock below the pane it splits; Home's pinned dock, a zoomed screen
    /// and a plain dock keep their routes.
    @Test func splitDownGrowsOnlyAnUnpinnedChatDock() {
        #expect(Self.chatDock.splitsDown(zoomed: false))
        #expect(!Self.chatDock.splitsDown(zoomed: true), "a zoomed screen shows the chat alone")
        #expect(!DockColumn(edge: .left, role: .agentChat, isPinned: true).splitsDown(zoomed: false), "Home opens beside its dock")
        #expect(!DockColumn(edge: .left).splitsDown(zoomed: false))
    }

    /// The native New Tab page (`tabs.nativeNewTabPage`) sends its picks the same way: a terminal or browser goes
    /// beside the chat, a chat stays in the dock (review of #28544 at a6f8b21a: its picks opened in the main pane).
    @Test func theNativePagesToolPicksGoBesideTheChat() {
        #expect(AgentPaneTabKind.terminal.opensBesideChat)
        #expect(AgentPaneTabKind.browser.opensBesideChat)
        #expect(!AgentPaneTabKind.agent.opensBesideChat)
    }

    /// A setup action that keeps its page or chat (Log In, Update, Open in Terminal) still opens beside the dock,
    /// leaving the page; with no strip beside the dock, the usual route (review of #28544 at 39fa77d8).
    @Test func aKeptPickInTheDockStillOpensInTheStrip() {
        #expect(ChatColumnPlacement.DockPick.resolve(hasStrip: true, keep: true) == .beside(closesPage: false))
        #expect(ChatColumnPlacement.DockPick.resolve(hasStrip: true, keep: false) == .beside(closesPage: true))
        #expect(ChatColumnPlacement.DockPick.resolve(hasStrip: false, keep: false) == .usual)
    }

    /// What a typed submission reads as decides where it opens, not the kind the field was on: `!ls` typed as a
    /// prompt is a terminal, which goes beside the chat (review of #28544 at 39fa77d8).
    @Test func aTypedCommandOpensBesideTheChatWhateverTheFieldsKind() {
        let resolver = OmniboxResolver()
        let typed = NewTabSubmit.plan(text: "!ls", search: false, agent: nil, resolver: resolver, home: nil)
        #expect(typed == .terminal(command: "ls"))
        #expect(typed.opensBesideChat)
        #expect(NewTabSubmit.plan(text: "fix the tests", search: false, agent: nil, resolver: resolver, home: nil).opensBesideChat == false)
        #expect(!NewTabSubmit.page.opensBesideChat)
        // A script's submission aimed at the dock opens where it asked (delta review of #28544 at 54e3d1bf).
        #expect(typed.opensBesideChat(origin: .user))
        #expect(!typed.opensBesideChat(origin: .cli))
        #expect(!typed.opensBesideChat(origin: .mcp))
    }
}

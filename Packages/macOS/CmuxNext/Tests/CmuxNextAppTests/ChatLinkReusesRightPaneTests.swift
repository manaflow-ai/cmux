import CmuxNextAgentPane
import CmuxNextLayout
@testable import CmuxNextApp
import Testing

/// Leo 2026-10-30, of an agent chat that opened a chat (and links) beside a page already open on its right:
/// "stupid animation to open up a tab in the main pane THEN opening up a right pane and animating that + stupid
/// to not reuse the existing opened fucking right pane", and "IT'S THE FUCKING SINGLE MAIN TO OTHER FUCKING".
/// What a chat opens goes to the pane already on its right, found up front so the tab is made there directly.
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

    /// The native New Tab page (`tabs.nativeNewTabPage`) sends its picks the same way: a terminal or browser goes
    /// beside the chat, a chat stays in the dock (review of #28544 at a6f8b21a: its picks opened in the main pane).
    @Test func theNativePagesToolPicksGoBesideTheChat() {
        #expect(NewTabPage.picksBeside(.terminal))
        #expect(NewTabPage.picksBeside(.browser))
        #expect(!NewTabPage.picksBeside(.agent))
    }
}

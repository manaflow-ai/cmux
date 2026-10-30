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
}

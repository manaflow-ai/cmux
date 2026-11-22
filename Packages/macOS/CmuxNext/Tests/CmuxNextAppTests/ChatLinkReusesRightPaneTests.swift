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
    /// The pane on the right is found by column order when no drawn frame shows it (a right dock, a scrolled column).
    @Test func thePaneOnTheRightIsFoundByColumnOrder() {
        #expect(LinkOpenPlacement<String>.paneRight(of: "chat", columns: [["chat"], ["page"]], takesTabs: { _ in true }, recency: []) == "page")
        #expect(LinkOpenPlacement<String>.paneRight(of: "chat", columns: [["chat"]], takesTabs: { _ in true }, recency: []) == nil)
        #expect(LinkOpenPlacement<String>(setting: .splitRight).target(source: "chat", takesTabs: true, right: "page") == .pane("page"))
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

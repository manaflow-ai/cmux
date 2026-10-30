import CmuxNextLayout
@testable import CmuxNextApp
import Testing

/// Leo 2026-10-30, of an agent chat that opened a chat (and links) beside a page already open on its right:
/// "stupid animation to open up a tab in the main pane THEN opening up a right pane and animating that + stupid
/// to not reuse the existing opened fucking right pane", and "IT'S THE FUCKING SINGLE MAIN TO OTHER FUCKING".
/// What a chat opens goes to the pane already on its right (ChatOpenDestination), found up front so the tab is
/// made there directly. Of new tabs (Cmd-T): "NOBODY FGUCKING ASKED FOR THIS ONE TOO": their route is base's.
struct ChatLinkReusesRightPaneTests {
    /// The pane on the right is found by column order when no drawn frame shows it (a right dock, a scrolled column).
    @Test func thePaneOnTheRightIsFoundByColumnOrder() {
        #expect(LinkOpenPlacement<String>.paneRight(of: "chat", columns: [["chat"], ["page"]], takesTabs: { _ in true }, recency: []) == "page")
        #expect(LinkOpenPlacement<String>.paneRight(of: "chat", columns: [["chat"]], takesTabs: { _ in true }, recency: []) == nil)
        #expect(LinkOpenPlacement<String>(setting: .splitRight).target(source: "chat", takesTabs: true, right: "page") == .pane("page"))
    }

    /// The chat's opens go to the right pane today; the switch is the one place that would change it.
    @Test func chatOpensGoToTheRightPane() {
        #expect(ChatOpenDestination.current == .rightPane)
    }

    /// Cmd-T and everything else main pane layout routes is as on base: a lone chat with a pane docked on its
    /// right still docks for a new tab (ChatColumnPlacement is unchanged by this PR).
    @Test func newTabsKeepBasesRoute() {
        let chat = LayoutColumn(id: "chat", root: .leaf("chat"))
        let right = LayoutColumn(id: "page", root: .leaf("page"), dock: DockColumn(edge: .right))
        #expect(ChatColumnPlacement.resolve(from: "chat", columns: [chat, right]) { _ in true } == .dockChat)
        #expect(ChatColumnPlacement.resolve(from: "chat", columns: [chat]) { _ in true } == .dockChat)
    }
}

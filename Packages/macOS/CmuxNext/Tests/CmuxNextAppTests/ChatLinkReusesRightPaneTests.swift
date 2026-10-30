import CmuxNextLayout
@testable import CmuxNextApp
import Testing

/// Leo 2026-10-30, of a GitHub pull request link clicked in an agent chat with a page already open on its
/// right: "stupid animation to open up a tab in the main pane THEN opening up a right pane and animating that +
/// stupid to not reuse the existing opened fucking right pane". With the chat alone in the strip and a pane
/// already docked on its right, main pane layout docked the chat to make a new right column (the link was made
/// in the chat's pane, then a new pane slid in from the right) instead of opening in the pane already there.
struct ChatLinkReusesRightPaneTests {
    private static let chat = LayoutColumn(id: "chat", root: .leaf("chat"))
    private static let right = LayoutColumn(id: "page", root: .leaf("page"), dock: DockColumn(edge: .right))

    @Test func aLoneChatWithAPaneOnItsRightDoesNotDockToMakeAnother() {
        // Nothing on the right: the chat docks and the link's pane becomes the column on its right, as before.
        #expect(ChatColumnPlacement.resolve(from: "chat", columns: [Self.chat]) { _ in true } == .dockChat)
        // A pane already on the right: no dock, no new pane; what the chat opens is a tab there.
        #expect(ChatColumnPlacement.resolve(from: "chat", columns: [Self.chat, Self.right]) { _ in true } == .tab(in: "page"),
                "the chat docked to make a second right pane beside the one already there")
        // The pane on the right the person used last, when that dock is split.
        let split = LayoutColumn(id: "page", root: .split("s", axis: .vertical, ratio: 0.5, a: .leaf("top"), b: .leaf("bottom")),
                                 dock: DockColumn(edge: .right))
        #expect(ChatColumnPlacement.resolve(from: "chat", columns: [Self.chat, split], recent: ["bottom", "chat"]) { _ in true }
                == .tab(in: "bottom"))
        // A pinned right dock closed to tabs cannot take it: the chat docks as before.
        let closed = LayoutColumn(id: "page", root: .leaf("page"), dock: DockColumn(edge: .right, isPinned: true))
        #expect(ChatColumnPlacement.resolve(from: "chat", columns: [Self.chat, closed]) { _ in true } == .dockChat)
        // A left or bottom dock is not on the chat's right.
        let left = LayoutColumn(id: "notes", root: .leaf("notes"), dock: DockColumn(edge: .left))
        #expect(ChatColumnPlacement.resolve(from: "chat", columns: [left, Self.chat]) { _ in true } == .dockChat)
    }

    /// The pane on the right is found by column order when no drawn frame shows it (a right dock, a scrolled
    /// column), so the link opens there instead of in a new split.
    @Test func thePaneOnTheRightIsFoundByColumnOrder() {
        #expect(LinkOpenPlacement<String>.paneRight(of: "chat", columns: [["chat"], ["page"]], takesTabs: { _ in true }, recency: []) == "page")
        let rule = LinkOpenPlacement<String>(setting: .splitRight)
        #expect(rule.target(source: "chat", takesTabs: true, right: "page") == .pane("page"), "a link split again beside the pane on the right")
    }
}

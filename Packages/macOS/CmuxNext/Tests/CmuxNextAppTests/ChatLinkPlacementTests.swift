@testable import CmuxNextApp
import CmuxNextLayout
import CmuxNextSettings
import Testing

/// Leo 2026-10-21: "WHY DID THIS NOT OPEN TO THE SIDE?" A GitHub link clicked in an agent chat
/// opened as a tab in the chat's own pane, covering the chat. And: "if the left side has a tab, any
/// link opened also goes on the left instead of opening a new split", then "open on right by
/// default". ``ChatLinkPlacement`` decides where a web link from a chat goes, by
/// `layout.linkPlacement`: on the right (the right pane focused last, else the rightmost, else a new
/// split), never the chat's pane, another chat or a pane on its left; Tab in the Same Pane keeps it
/// in the agent pane.
struct ChatLinkPlacementTests {
    private typealias Target = LinkOpenPlacement<String>.Target

    /// `right`: the panes right of "chat", one group per column, left to right.
    private static func target(_ right: [[String]], _ setting: LinkPlacement = .fallback, takesTabs: (String) -> Bool = { _ in true },
                               recency: [String] = []) -> Target? {
        ChatLinkPlacement.target(setting, chat: "chat", right: right, takesTabs: takesTabs, recency: recency)
    }

    @Test func onTheRightIsTheDefault() {
        #expect(LinkPlacement.fallback == .splitRight)
        #expect(Self.target([]) == .splitRight(of: "chat"))
        #expect(Self.target([["opened"]]) == .pane("opened"))
    }

    /// No pane right of the chat (alone, or with a browser on its left, which the caller never lists):
    /// a new split on its right, never the left pane.
    @Test func noRightPaneMakesANewRightSplit() {
        #expect(Self.target([]) == .splitRight(of: "chat"))
        #expect(Self.target([[]], recency: ["browser-on-the-left"]) == .splitRight(of: "chat"))
        #expect(Self.target([], .newColumn) == .newColumn(rightOf: "chat"))
    }

    /// Several panes on the right: the one the person focused last wins over the rightmost.
    @Test func theFocusedRightSplitWinsOverTheRightmost() {
        #expect(Self.target([["middle"], ["right"]], recency: ["chat", "middle", "right"]) == .pane("middle"))
        #expect(Self.target([["top", "bottom"]], recency: ["chat", "bottom"]) == .pane("bottom"))
    }

    /// None of the right panes was focused: the rightmost column, its right edge first, top first.
    @Test func withNoFocusedRightPaneTheRightmostWins() {
        #expect(Self.target([["middle"], ["right"]], recency: ["chat", "browser-on-the-left"]) == .pane("right"))
        #expect(Self.target([["middle"], ["edge-top", "edge-bottom"]]) == .pane("edge-top"))
    }

    /// A pane that takes no tabs (Home's pinned dock) or shows another agent chat is skipped.
    @Test func panesThatTakeNoTabsOrShowAChatAreSkipped() {
        let takes: (String) -> Bool = { !["pinned", "other-chat"].contains($0) }
        #expect(Self.target([["strip"], ["pinned"]], takesTabs: takes) == .pane("strip"))
        #expect(Self.target([["other-chat"]], takesTabs: takes, recency: ["other-chat"]) == .splitRight(of: "chat"))
    }

    /// Whatever the layout, a link on the right never covers the chat, even when the chat is listed.
    @Test(arguments: [LinkPlacement.splitRight, .newColumn])
    func theChatIsNeverTheTarget(_ setting: LinkPlacement) {
        for right in [[], [["chat"]], [["chat", "r"]], [["r"], ["chat"]]] as [[[String]]] {
            #expect(Self.target(right, setting, recency: ["chat"]) != .pane("chat"))
        }
    }

    /// Tab in the Same Pane: "in the agent pane", by the rules for any page (nil here).
    @Test func samePaneKeepsTheLinkInTheAgentPane() {
        #expect(Self.target([["opened"]], .samePane) == nil)
        #expect(Self.target([], .samePane) == nil)
    }

    /// Right edges come from the split tree: a side-by-side split's right side, both halves of a
    /// stacked one.
    @Test func theRightEdgeOfASplitTree() {
        let tree = SplitNode.split("s1", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                                   b: .split("s2", axis: .vertical, ratio: 0.5, a: .leaf("b"),
                                             b: .split("s3", axis: .horizontal, ratio: 0.5, a: .leaf("c"), b: .leaf("d"))))
        #expect(ChatLinkPlacement.rightEdge(of: tree) == ["b", "d"])
        #expect(ChatLinkPlacement.rightEdge(of: .leaf("a")) == ["a"])
    }

    /// In the chat's own split tree, only panes beside it on its right count: not the left side,
    /// not panes stacked above or below it.
    @Test func panesRightOfTheChatInItsTree() {
        // [left | [chat / below] | right]
        let tree = SplitNode.split("s1", axis: .horizontal, ratio: 0.3, a: .leaf("left"),
                                   b: .split("s2", axis: .horizontal, ratio: 0.5,
                                             a: .split("s3", axis: .vertical, ratio: 0.5, a: .leaf("chat"), b: .leaf("below")),
                                             b: .leaf("right")))
        #expect(ChatLinkPlacement.panes(rightOf: "chat", in: tree) == ["right"])
        #expect(ChatLinkPlacement.panes(rightOf: "right", in: tree).isEmpty)
        #expect(ChatLinkPlacement.panes(rightOf: "left", in: tree) == ["chat", "below", "right"])
    }

    /// The screen's columns: a browser column left of the chat is never on its right; a bottom band
    /// is not beside it; the chat's own column contributes only what is right of the chat.
    @Test func theRightSideOfAScreen() {
        let columns = [
            LayoutColumn(id: "browser", root: .leaf("browser")),
            LayoutColumn(id: "chat", root: .split("s1", axis: .horizontal, ratio: 0.5, a: .leaf("chat"), b: .leaf("beside"))),
            LayoutColumn(id: "band", root: .leaf("band"), dock: DockColumn(edge: .bottom)),
            LayoutColumn(id: "strip", root: .split("s2", axis: .horizontal, ratio: 0.5, a: .leaf("inner"), b: .leaf("edge"))),
        ]
        #expect(ChatLinkPlacement.rightSide(of: "chat", in: columns) == [["beside"], ["edge", "inner"]])
        #expect(ChatLinkPlacement.rightSide(of: "missing", in: columns).isEmpty)
        let right = ChatLinkPlacement.rightSide(of: "chat", in: columns)
        #expect(ChatLinkPlacement.target(.splitRight, chat: "chat", right: right, takesTabs: { _ in true },
                                         recency: ["browser", "chat"]) == .pane("edge"))
    }
}

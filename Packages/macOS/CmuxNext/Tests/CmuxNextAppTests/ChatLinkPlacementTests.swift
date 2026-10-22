@testable import CmuxNextApp
import CmuxNextLayout
import CmuxNextSettings
import Testing

/// Leo 2026-10-21: "WHY DID THIS NOT OPEN TO THE SIDE?" A GitHub link clicked in an agent chat
/// opened as a tab in the chat's own pane, covering the chat. And: "if the left side has a tab, any
/// link opened also goes on the left instead of opening a new split. By default, things going to the
/// rightmost split is the thing to try." ``ChatLinkPlacement`` (`links.openTarget`) decides where a
/// link from a chat goes: the rightmost split of its screen, a new split right of the chat when the
/// chat is the rightmost split, never the chat's pane or a pane on its left.
struct ChatLinkPlacementTests {
    private typealias Target = LinkOpenPlacement<String>.Target

    private static func target(_ columns: [[String]], _ setting: ChatLinkTarget = .fallback, chat: String = "chat",
                               takesTabs: (String) -> Bool = { _ in true }, recency: [String] = []) -> Target? {
        ChatLinkPlacement.target(setting, chat: chat, columns: columns, chatColumn: columns.firstIndex { $0.contains(chat) },
                                 takesTabs: takesTabs, recency: recency)
    }

    @Test func rightmostIsTheDefault() {
        #expect(ChatLinkTarget.fallback == .rightmost)
    }

    /// The reported case: a browser on the left, the chat on the right. The link never goes left
    /// and never covers the chat: a new split opens on the chat's right.
    @Test func aBrowserOnTheLeftNeverGetsTheLink() {
        #expect(Self.target([["browser"], ["chat"]]) == .splitRight(of: "chat"))
        #expect(Self.target([["browser"], ["chat"]], recency: ["browser", "chat"]) == .splitRight(of: "chat"))
    }

    @Test func aChatAloneOnItsScreenGetsANewSplitOnItsRight() {
        #expect(Self.target([["chat"]]) == .splitRight(of: "chat"))
    }

    /// The first open made the split on the right; the next one reuses it (no split per click).
    @Test func thePaneOnTheRightIsReused() {
        #expect(Self.target([["chat"], ["opened"]]) == .pane("opened"))
    }

    /// Several columns on the right: the rightmost one gets the link, not the one beside the chat.
    @Test func theRightmostColumnWins() {
        #expect(Self.target([["left"], ["chat"], ["middle"], ["right"]], recency: ["middle"]) == .pane("right"))
    }

    /// The rightmost column split top and bottom: the more recently used of its panes, else the top one.
    @Test func inTheRightmostColumnTheRecentPaneWins() {
        #expect(Self.target([["chat"], ["top", "bottom"]]) == .pane("top"))
        #expect(Self.target([["chat"], ["top", "bottom"]], recency: ["chat", "bottom", "top"]) == .pane("bottom"))
    }

    /// A pane that takes no new tabs (a pinned dock) is skipped; with nothing else on the right the
    /// chat gets a split.
    @Test func panesThatTakeNoTabsAreSkipped() {
        let takes: (String) -> Bool = { $0 != "pinned" }
        #expect(Self.target([["chat"], ["strip"], ["pinned"]], takesTabs: takes) == .pane("strip"))
        #expect(Self.target([["left"], ["chat"], ["pinned"]], takesTabs: takes) == .splitRight(of: "chat"))
    }

    /// The chat's own column holds another pane on its right edge (below it): that pane is a
    /// rightmost split, so it gets the link instead of a new split.
    @Test func anotherPaneOnTheChatsRightEdgeIsUsed() {
        #expect(Self.target([["left"], ["chat", "below"]]) == .pane("below"))
    }

    @Test func newSplitAlwaysSplitsRightOfTheChat() {
        for columns in [[["chat"]], [["browser"], ["chat"]], [["chat"], ["opened"]]] {
            #expect(Self.target(columns, .newSplit) == .splitRight(of: "chat"))
        }
    }

    /// Same Tab keeps the old rules (a tab in the chat's pane, or main pane layout's column).
    @Test func sameTabLeavesItToThePageRules() {
        #expect(Self.target([["browser"], ["chat"]], .sameTab) == nil)
        #expect(Self.target([["chat"], ["opened"]], .sameTab) == nil)
    }

    /// Whatever the setting, a link from a chat never lands in a pane left of the chat, nor as a tab
    /// over the chat itself.
    @Test(arguments: [ChatLinkTarget.rightmost, .newSplit])
    func neverTheLeftNorTheChat(_ setting: ChatLinkTarget) {
        let layouts: [[[String]]] = [[["chat"]], [["l1"], ["chat"]], [["l1", "l2"], ["chat"], ["r"]], [["l1"], ["chat", "below"]]]
        for columns in layouts {
            let target = Self.target(columns, setting, recency: ["l1", "l2"])
            #expect(target != .pane("chat"))
            #expect(target != .pane("l1"))
            #expect(target != .pane("l2"))
        }
    }

    /// The chat's column is unknown (it is not on the screen): a split on its right, never a guess.
    @Test func anUnknownColumnSplitsRight() {
        #expect(ChatLinkPlacement.target(.rightmost, chat: "chat", columns: [["a"]], chatColumn: nil,
                                         takesTabs: { _ in true }, recency: []) == .splitRight(of: "chat"))
    }

    /// Right edges come from the split tree: a side-by-side split's right side, both halves of a
    /// stacked one.
    @Test func theRightEdgeOfASplitTree() {
        let (a, b, c, d): (PaneID, PaneID, PaneID, PaneID) = ("a", "b", "c", "d")
        let tree = SplitNode.split("s1", axis: .horizontal, ratio: 0.5, a: .leaf(a),
                                   b: .split("s2", axis: .vertical, ratio: 0.5, a: .leaf(b),
                                             b: .split("s3", axis: .horizontal, ratio: 0.5, a: .leaf(c), b: .leaf(d))))
        #expect(ChatLinkPlacement.rightEdge(of: tree) == [b, d])
        #expect(ChatLinkPlacement.rightEdge(of: .leaf(a)) == [a])
    }

    /// A screen's columns: left dock, strip, right dock in order; a bottom band is not beside the chat.
    @Test func columnsSkipBandsAndFindTheChat() {
        let (chat, strip, right, band): (PaneID, PaneID, PaneID, PaneID) = ("chat", "strip", "right", "band")
        let columns = [
            LayoutColumn(id: "chat", root: .leaf(chat), dock: DockColumn(edge: .left, role: .agentChat)),
            LayoutColumn(id: "strip", root: .leaf(strip)),
            LayoutColumn(id: "band", root: .leaf(band), dock: DockColumn(edge: .bottom)),
            LayoutColumn(id: "right", root: .leaf(right), dock: DockColumn(edge: .right)),
        ]
        let found = ChatLinkPlacement.columns(columns, chat: chat)
        #expect(found.edges == [[chat], [strip], [right]])
        #expect(found.chatColumn == 0)
    }
}

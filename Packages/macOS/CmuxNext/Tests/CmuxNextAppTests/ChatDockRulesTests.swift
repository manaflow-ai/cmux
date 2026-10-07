import CmuxNextBridge
import CmuxNextLayout
import Testing
@testable import CmuxNextApp

/// The chat dock is a docked region, not a split that happens to sit on the
/// left (lawrence-call-1006 D): it can't be split and holds only agent chats.
@Suite struct ChatDockRulesTests {
    private let chatDock = DockColumn(edge: .left, role: .agentChat)

    private func column(_ id: String, _ panes: [String], dock: DockColumn? = nil) -> LayoutColumn {
        let leaves = panes.map { SplitNode.leaf(LayoutPaneID($0)) }
        let root = leaves.dropFirst().reduce(leaves[0]) { a, b in
            .split(SplitID("s-\(id)-\(a.panes.count)"), axis: .vertical, ratio: 0.5, a: a, b: b)
        }
        return LayoutColumn(id: LayoutColumnID(id), root: root, dock: dock)
    }

    private var columns: [LayoutColumn] {
        [column("c1", ["chat"], dock: chatDock), column("c2", ["term", "logs"]),
         column("c3", ["notes"], dock: DockColumn(edge: .right))]
    }

    @Test func theChatDockCannotBeSplit() {
        #expect(ChatDockRules.refusesSplit(of: LayoutPaneID("chat"), columns: columns))
    }

    @Test func otherPanesSplit() {
        for pane in ["term", "logs", "notes", "gone"] {
            #expect(!ChatDockRules.refusesSplit(of: LayoutPaneID(pane), columns: columns), "\(pane)")
        }
    }

    @Test func theChatDockTakesOnlyChats() {
        #expect(ChatDockRules.refusesTab(isChat: false, into: LayoutPaneID("chat"), columns: columns))
        #expect(!ChatDockRules.refusesTab(isChat: true, into: LayoutPaneID("chat"), columns: columns))
    }

    @Test func otherPanesTakeAnyTab() {
        #expect(!ChatDockRules.refusesTab(isChat: false, into: LayoutPaneID("term"), columns: columns))
        #expect(!ChatDockRules.refusesTab(isChat: false, into: LayoutPaneID("notes"), columns: columns))
    }
}

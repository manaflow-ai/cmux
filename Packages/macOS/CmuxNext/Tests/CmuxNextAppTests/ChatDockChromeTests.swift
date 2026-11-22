import CmuxNextBridge
import CmuxNextLayout
import Testing
@testable import CmuxNextApp

/// The agent chat is a docked column with no tab bar by default
/// (lawrence-call-1006 D): its strip shows only once it holds two tabs.
@Suite struct ChatDockChromeTests {
    private let chatDock = DockColumn(edge: .left, role: .agentChat)

    private func column(_ id: String, _ panes: [String], dock: DockColumn? = nil) -> LayoutColumn {
        let leaves = panes.map { SplitNode.leaf(LayoutPaneID($0)) }
        let root = leaves.dropFirst().reduce(leaves[0]) { a, b in
            .split(SplitID("s-\(id)-\(a.panes.count)"), axis: .vertical, ratio: 0.5, a: a, b: b)
        }
        return LayoutColumn(id: LayoutColumnID(id), root: root, dock: dock)
    }

    private func hides(_ pane: String, _ columns: [LayoutColumn], tabs: Int = 1, lone: Bool = false) -> Bool {
        ChatDockChrome.hidesStrip(pane: LayoutPaneID(pane), columns: columns, tabCount: tabs, isLoneChat: lone)
    }

    @Test func theChatDockShowsNoStripWithOneTab() {
        let columns = [column("c1", ["chat"], dock: chatDock), column("c2", ["term"])]
        #expect(hides("chat", columns))
    }

    @Test func theChatDockShowsItsStripWithTwoTabs() {
        let columns = [column("c1", ["chat"], dock: chatDock), column("c2", ["term"])]
        #expect(!hides("chat", columns, tabs: 2))
    }

    /// A chat alone on its screen docks when the first tool opens
    /// (ChatColumnPlacement); until then it has no strip either.
    @Test func aLoneChatShowsNoStrip() {
        #expect(hides("chat", [column("c1", ["chat"])], lone: true))
    }

    @Test func otherPanesKeepTheirStrip() {
        let columns = [column("c1", ["chat"], dock: chatDock), column("c2", ["term"]),
                       column("c3", ["notes"], dock: DockColumn(edge: .right))]
        #expect(!hides("term", columns))
        #expect(!hides("notes", columns))
        #expect(!hides("solo", [column("c9", ["solo"])]))
        #expect(!hides("gone", columns))
    }

    /// Cursor review (#18223): a chat alone in the strip beside the chat dock
    /// (a New Tab page that became a chat) is not the screen's lone chat: it
    /// docks nothing, so it keeps its strip.
    @Test func aLoneChatBesideTheChatDockKeepsItsStrip() {
        let columns = [column("c0", ["docked"], dock: chatDock), column("c1", ["chat"])]
        #expect(!hides("chat", columns, lone: true))
    }
}

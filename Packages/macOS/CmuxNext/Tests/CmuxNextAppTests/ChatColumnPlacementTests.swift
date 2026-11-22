import CmuxNextBridge
import CmuxNextLayout
import Testing
@testable import CmuxNextApp

/// Two columns like the Codex app (lawrence-call-1006 D): the agent chat
/// is a docked region on the left (a dock column with the agent chat
/// role), and a person's new terminal, browser or New Tab page opened from
/// it is a tab in the scrolling strip, never a tab of the dock.
@Suite struct ChatColumnPlacementTests {
    private let chatDock = DockColumn(edge: .left, role: .agentChat)

    private func column(_ id: String, _ panes: [String], dock: DockColumn? = nil) -> LayoutColumn {
        let leaves = panes.map { SplitNode.leaf(LayoutPaneID($0)) }
        let root = leaves.dropFirst().reduce(leaves[0]) { a, b in
            .split(SplitID("s-\(id)-\(a.panes.count)"), axis: .vertical, ratio: 0.5, a: a, b: b)
        }
        return LayoutColumn(id: LayoutColumnID(id), root: root, dock: dock)
    }

    private func resolve(from pane: String, _ columns: [LayoutColumn], recent: [String] = [],
                         loneChat: Set<String> = [], zoomed: Bool = false) -> ChatColumnPlacement {
        ChatColumnPlacement.resolve(from: LayoutPaneID(pane), columns: columns, recent: recent.map { LayoutPaneID($0) },
                                    zoomed: zoomed) {
            loneChat.contains($0.id.rawValue)
        }
    }

    @Test func theDockedChatSendsTheToolToTheStrip() {
        let columns = [column("c1", ["chat"], dock: chatDock), column("c2", ["term", "logs"])]
        #expect(resolve(from: "chat", columns) == .tab(in: LayoutPaneID("term")))
    }

    @Test func theStripPaneFocusedLastGetsTheTab() {
        let columns = [column("c1", ["chat"], dock: chatDock), column("c2", ["term", "logs"]), column("c3", ["web"])]
        #expect(resolve(from: "chat", columns, recent: ["chat", "logs", "web"]) == .tab(in: LayoutPaneID("logs")))
    }

    @Test func theDockedChatSkipsOtherDocks() {
        let columns = [column("c1", ["chat"], dock: chatDock),
                       column("c3", ["notes"], dock: DockColumn(edge: .right)), column("c2", ["term"])]
        #expect(resolve(from: "chat", columns, recent: ["notes"]) == .tab(in: LayoutPaneID("term")))
    }

    /// Cursor review (#18170): the daemon never keeps a dock without a
    /// scrolling column (an all-docked screen undocks), so a chat dock with
    /// no strip is not a state to build a column for: the tab stays.
    @Test func theDockedChatWithoutAStripStaysHere() {
        #expect(resolve(from: "chat", [column("c1", ["chat"], dock: chatDock)]) == .here)
    }

    /// Cursor review (#18170): a zoomed screen maps to its zoomed pane
    /// alone, so a zoomed chat looks like a lone chat. Zoom hides the strip
    /// and any chat dock; nothing docks or moves until it ends.
    @Test func aZoomedChatDocksNothing() {
        #expect(resolve(from: "chat", [column("c1", ["chat"])], loneChat: ["c1"], zoomed: true) == .here)
    }

    @Test func aChatAloneOnItsScreenDocks() {
        #expect(resolve(from: "chat", [column("c1", ["chat"])], loneChat: ["c1"]) == .dockChat)
        let besideADock = [column("c1", ["chat"]), column("c3", ["notes"], dock: DockColumn(edge: .right))]
        #expect(resolve(from: "chat", besideADock, loneChat: ["c1"]) == .dockChat)
    }

    /// The role, not the content, makes the chat dock: chats a person put
    /// in a plain dock, or beside other columns, are normal panes.
    @Test func chatsOutsideTheChatDockAreNormalPanes() {
        let handDocked = [column("c1", ["chat"], dock: DockColumn(edge: .left)), column("c2", ["term"])]
        #expect(resolve(from: "chat", handDocked, loneChat: ["c1"]) == .here)
        let beside = [column("c1", ["chat"]), column("c2", ["term"])]
        #expect(resolve(from: "chat", beside, loneChat: ["c1"]) == .here)
    }

    @Test func aSecondChatDocksNothing() {
        let columns = [column("c0", ["docked"], dock: chatDock), column("c1", ["chat"])]
        #expect(resolve(from: "chat", columns, loneChat: ["c1"]) == .here)
    }

    @Test func toolsOpenedInTheStripStayInTheirPane() {
        let columns = [column("c1", ["chat"], dock: chatDock), column("c2", ["term"])]
        #expect(resolve(from: "term", columns) == .here)
        #expect(resolve(from: "solo", [column("c9", ["solo"])]) == .here)
    }

    /// A new workspace's screen is one split tree, not columns: the chat
    /// alone there still sees its (implicit) column.
    @Test func aSplitTreeScreenIsOneImplicitColumn() {
        let screen = LayoutScreen(id: "s", name: "1", layout: .splits(.leaf(LayoutPaneID("chat"))))
        let columns = ChatColumnPlacement.columns(of: screen, containing: LayoutPaneID("chat"))
        #expect(columns.map(\.id) == [screen.implicitColumnID])
        #expect(ChatColumnPlacement.resolve(from: LayoutPaneID("chat"), columns: columns) { _ in true } == .dockChat)
    }

    @Test func aPaneOutsideTheColumnsStaysHere() {
        #expect(resolve(from: "gone", [column("c1", ["chat"], dock: chatDock)]) == .here)
    }
}

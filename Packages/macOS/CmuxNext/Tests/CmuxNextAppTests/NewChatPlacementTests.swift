import CmuxNextBridge
import CmuxNextLayout
import Testing
@testable import CmuxNextApp

/// Every new agent chat opens as the docked chat column, never as a tab in
/// the strip (lawrence-call-1006 D).
@Suite struct NewChatPlacementTests {
    private let chatDock = DockColumn(edge: .left, role: .agentChat)

    private func column(_ id: String, _ panes: [String], dock: DockColumn? = nil) -> LayoutColumn {
        let leaves = panes.map { SplitNode.leaf(LayoutPaneID($0)) }
        let root = leaves.dropFirst().reduce(leaves[0]) { a, b in
            .split(SplitID("s-\(id)-\(a.panes.count)"), axis: .vertical, ratio: 0.5, a: a, b: b)
        }
        return LayoutColumn(id: LayoutColumnID(id), root: root, dock: dock)
    }

    private func resolve(from pane: String, _ columns: [LayoutColumn], lone: Bool = false) -> NewChatPlacement {
        NewChatPlacement.resolve(from: LayoutPaneID(pane), columns: columns, isLoneChat: lone)
    }

    @Test func aNewChatJoinsTheChatDock() {
        let columns = [column("c1", ["chat"], dock: chatDock), column("c2", ["term", "logs"])]
        #expect(resolve(from: "logs", columns) == .dock(LayoutPaneID("chat")))
        #expect(resolve(from: "chat", columns) == .dock(LayoutPaneID("chat")))
    }

    @Test func aNewChatBesideToolsMakesTheChatDock() {
        #expect(resolve(from: "term", [column("c1", ["term"])]) == .newDock)
        let columns = [column("c1", ["term"]), column("c2", ["web"]), column("c3", ["notes"], dock: DockColumn(edge: .right))]
        #expect(resolve(from: "web", columns) == .newDock)
    }

    /// A lone chat docks when the first tool opens; a second chat joins its pane.
    @Test func aNewChatFromALoneChatStaysWithIt() {
        #expect(resolve(from: "chat", [column("c1", ["chat"])], lone: true) == .here)
    }

    @Test func aPaneOutsideTheColumnsStaysHere() {
        #expect(resolve(from: "gone", [column("c1", ["term"])]) == .here)
    }
}

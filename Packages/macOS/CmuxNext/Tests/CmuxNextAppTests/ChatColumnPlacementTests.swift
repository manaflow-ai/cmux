import CmuxNextBridge
import CmuxNextLayout
import Testing
@testable import CmuxNextApp

/// Two columns like the Codex app (lawrence-call-1006 D): a person's new
/// terminal or browser opened from an agent chat never lands in the chat's
/// column. The chat stays alone, docked on the left, and tools are tabs in
/// the column to its right.
@Suite struct ChatColumnPlacementTests {
    private func column(_ id: String, _ panes: [String], dock: DockColumn? = nil) -> LayoutColumn {
        let leaves = panes.map { SplitNode.leaf(LayoutPaneID($0)) }
        let root = leaves.dropFirst().reduce(leaves[0]) { a, b in
            .split(SplitID("s-\(id)-\(a.panes.count)"), axis: .vertical, ratio: 0.5, a: a, b: b)
        }
        return LayoutColumn(id: LayoutColumnID(id), root: root, dock: dock)
    }

    private func resolve(from pane: String, _ columns: [LayoutColumn], chat: Set<String>) -> ChatColumnPlacement {
        ChatColumnPlacement.resolve(from: LayoutPaneID(pane), columns: columns) { chat.contains($0.id.rawValue) }
    }

    @Test func aChatAloneOnTheScreenGetsANewColumnAndDocksLeft() {
        let placement = resolve(from: "chat", [column("c1", ["chat"])], chat: ["c1"])
        #expect(placement == .newColumnDockingChat(LayoutColumnID("c1")))
    }

    @Test func aDockedChatSendsTheToolToTheStrip() {
        let columns = [column("c1", ["chat"], dock: DockColumn(edge: .left)), column("c2", ["term", "logs"])]
        #expect(resolve(from: "chat", columns, chat: ["c1"]) == .tab(in: LayoutPaneID("term")))
    }

    @Test func anUndockedChatSendsTheToolToTheColumnOnItsRight() {
        let columns = [column("c0", ["left"]), column("c1", ["chat"]), column("c2", ["right"])]
        #expect(resolve(from: "chat", columns, chat: ["c1"]) == .tab(in: LayoutPaneID("right")))
    }

    @Test func anUndockedLastChatColumnUsesTheNearestColumnOnItsLeft() {
        let columns = [column("c0", ["far"]), column("c1", ["near"]), column("c2", ["chat"])]
        #expect(resolve(from: "chat", columns, chat: ["c2"]) == .tab(in: LayoutPaneID("near")))
    }

    @Test func aDockedChatSkipsOtherDocks() {
        let columns = [column("c1", ["chat"], dock: DockColumn(edge: .left)),
                       column("c3", ["notes"], dock: DockColumn(edge: .right)), column("c2", ["term"])]
        #expect(resolve(from: "chat", columns, chat: ["c1"]) == .tab(in: LayoutPaneID("term")))
    }

    @Test func toolsOpenedOutsideAChatColumnStayInTheirPane() {
        let columns = [column("c1", ["chat"], dock: DockColumn(edge: .left)), column("c2", ["term"])]
        #expect(resolve(from: "term", columns, chat: ["c1"]) == .here)
        #expect(resolve(from: "solo", [column("c9", ["solo"])], chat: []) == .here)
    }

    @Test func aPaneOutsideTheColumnsStaysHere() {
        #expect(resolve(from: "gone", [column("c1", ["chat"])], chat: ["c1"]) == .here)
    }
}

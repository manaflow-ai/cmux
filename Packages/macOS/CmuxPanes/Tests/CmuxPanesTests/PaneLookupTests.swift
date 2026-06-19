import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

@Suite struct PaneLookupTests {
    private func pane(_ id: String) -> ExternalTreeNode {
        .pane(ExternalPaneNode(id: id, frame: PixelRect(x: 0, y: 0, width: 100, height: 100), tabs: [], selectedTabId: nil))
    }

    private func split(_ id: String, _ first: ExternalTreeNode, _ second: ExternalTreeNode) -> ExternalTreeNode {
        .split(ExternalSplitNode(id: id, orientation: "horizontal", dividerPosition: 0.5, first: first, second: second))
    }

    @Test func containsPaneFindsLeafAndMissing() {
        let tree = split("s1", pane("a"), split("s2", pane("b"), pane("c")))
        #expect(tree.containsPane("a"))
        #expect(tree.containsPane("b"))
        #expect(tree.containsPane("c"))
        #expect(!tree.containsPane("z"))
    }

    @Test func containsPaneOnLoneLeaf() {
        #expect(pane("a").containsPane("a"))
        #expect(!pane("a").containsPane("b"))
    }

    /// The nearest split separating two panes is the lowest split whose two
    /// children each hold exactly one of the panes.
    @Test func splitIdJoiningPanesReturnsNearestSeparatingSplit() {
        let root = UUID()
        let inner = UUID()
        let tree = split(root.uuidString, pane("a"), split(inner.uuidString, pane("b"), pane("c")))
        // a vs b: separated at the root.
        #expect(tree.splitIdJoiningPanes("a", "b") == root)
        // b vs c: separated at the inner split.
        #expect(tree.splitIdJoiningPanes("b", "c") == inner)
        // order-independent.
        #expect(tree.splitIdJoiningPanes("c", "a") == root)
    }

    @Test func splitIdJoiningPanesNilWhenPaneAbsent() {
        let tree = split(UUID().uuidString, pane("a"), pane("b"))
        #expect(tree.splitIdJoiningPanes("a", "z") == nil)
    }

    /// A non-UUID split id parses to nil, matching the legacy guard.
    @Test func splitIdJoiningPanesNilWhenSplitIdNotUUID() {
        let tree = split("not-a-uuid", pane("a"), pane("b"))
        #expect(tree.splitIdJoiningPanes("a", "b") == nil)
    }

    @Test func splitIdJoiningPanesNilOnLoneLeaf() {
        #expect(pane("a").splitIdJoiningPanes("a", "a") == nil)
    }
}

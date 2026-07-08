import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

@Suite struct SpatialOrderTests {
    private func pane(_ id: String) -> ExternalTreeNode {
        .pane(ExternalPaneNode(id: id, frame: PixelRect(x: 0, y: 0, width: 100, height: 100), tabs: [], selectedTabId: nil))
    }

    /// Depth-first, first/top before second/bottom: the on-screen order.
    @Test func orderedPaneIdsWalksDepthFirst() {
        let tree = ExternalTreeNode.split(ExternalSplitNode(
            id: "s1", orientation: "horizontal", dividerPosition: 0.5,
            first: pane("a"),
            second: .split(ExternalSplitNode(
                id: "s2", orientation: "vertical", dividerPosition: 0.5,
                first: pane("b"), second: pane("c")
            ))
        ))
        #expect(tree.orderedPaneIds == ["a", "b", "c"])
    }

    /// Pane order then tab order, deduplicated, then stable fallback order.
    @Test func orderedPanelIdsUsesPaneTabsThenFallback() {
        let p1 = UUID(), p2 = UUID(), p3 = UUID(), orphan = UUID()
        let tree = ExternalTreeNode.split(ExternalSplitNode(
            id: "s1", orientation: "horizontal", dividerPosition: 0.5,
            first: pane("a"), second: pane("b")
        ))
        let result = tree.orderedPanelIds(
            paneTabs: ["a": [p1, p2], "b": [p3, p1]],
            fallbackPanelIds: [orphan, p2]
        )
        #expect(result == [p1, p2, p3, orphan])
    }
}

import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

@Suite struct SpatialOrderTests {
    private func pane(_ id: String) -> ExternalTreeNode {
        .pane(ExternalPaneNode(id: id, frame: PixelRect(x: 0, y: 0, width: 100, height: 100), tabs: [], selectedTabId: nil))
    }

    private func paneId(_ index: Int) -> PaneID {
        PaneID(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
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

    @Test func paneCycleNavigatorWrapsForwardAndBackward() {
        let panes = [paneId(1), paneId(2), paneId(3)]
        let navigator = PaneCycleNavigator()

        #expect(navigator.targetPane(
            orderedPaneIds: panes.map(\.id),
            livePaneIds: panes,
            focusedPaneId: panes[0],
            forward: true
        ) == panes[1])
        #expect(navigator.targetPane(
            orderedPaneIds: panes.map(\.id),
            livePaneIds: panes,
            focusedPaneId: panes[2],
            forward: true
        ) == panes[0])
        #expect(navigator.targetPane(
            orderedPaneIds: panes.map(\.id),
            livePaneIds: panes,
            focusedPaneId: panes[0],
            forward: false
        ) == panes[2])
    }

    @Test func paneCycleNavigatorRejectsInvalidCycleInputs() {
        let panes = [paneId(1), paneId(2)]
        let stalePane = paneId(3)
        let navigator = PaneCycleNavigator()

        #expect(navigator.targetPane(
            orderedPaneIds: [panes[0].id],
            livePaneIds: panes,
            focusedPaneId: panes[0],
            forward: true
        ) == nil)
        #expect(navigator.targetPane(
            orderedPaneIds: panes.map(\.id),
            livePaneIds: panes,
            focusedPaneId: stalePane,
            forward: true
        ) == nil)
        #expect(navigator.targetPane(
            orderedPaneIds: [panes[0].id, stalePane.id],
            livePaneIds: panes,
            focusedPaneId: panes[0],
            forward: true
        ) == nil)
    }
}

import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Deep split trees leave panes with no room below their tab strip
/// ("collapsed", follow-up of #15771).
@Suite struct MinimumPaneSizeTests {
    /// A vertical chain a / (b / (c / (d / e))), each split at 0.5.
    private func chain(_ count: Int, axis: SplitAxis) -> SplitNode {
        var node = SplitNode.leaf(PaneID("p\(count - 1)"))
        for index in stride(from: count - 2, through: 0, by: -1) {
            node = .split(SplitID("s\(index)"), axis: axis, ratio: 0.5, a: .leaf(PaneID("p\(index)")), b: node)
        }
        return node
    }

    /// Five panes in 465 pt (93 pt each would fit a 28 pt strip plus four
    /// rows); without subtree minimums the innermost panes get 28 pt.
    @Test func deepChainKeepsEveryPaneAtTheMinimumHeight() {
        let tree = chain(5, axis: .vertical)
        let result = SplitGeometry.layout(tree, in: CGRect(x: 0, y: 0, width: 800, height: 465), style: LayoutStyle())
        #expect(result.panes.count == 5)
        for (pane, frame) in result.panes {
            #expect(frame.height >= 92 - 0.5, "\(pane) is \(frame.height) pt tall")
        }
    }
}

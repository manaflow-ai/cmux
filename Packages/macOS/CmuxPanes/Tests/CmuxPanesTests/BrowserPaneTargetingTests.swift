import CoreGraphics
import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

@Suite struct BrowserPaneTargetingTests {
    private func pane(_ id: String) -> ExternalTreeNode {
        .pane(ExternalPaneNode(id: id, frame: PixelRect(x: 0, y: 0, width: 100, height: 100), tabs: [], selectedTabId: nil))
    }

    private func split(
        _ id: String,
        orientation: String = "horizontal",
        divider: Double = 0.5,
        _ first: ExternalTreeNode,
        _ second: ExternalTreeNode
    ) -> ExternalTreeNode {
        .split(ExternalSplitNode(id: id, orientation: orientation, dividerPosition: divider, first: first, second: second))
    }

    /// The path unwinds leaf-last: the deepest split is first, the root split
    /// last, and each breadcrumb names the branch descended toward the pane.
    @Test func browserPathToPaneUnwindsLeafLast() {
        let tree = split("root", pane("a"), split("inner", pane("b"), pane("c")))
        let path = try! #require(tree.browserPathToPane(targetPaneId: "c"))
        #expect(path.count == 2)
        #expect(path[0].split.id == "inner")
        #expect(path[0].branch == .second)
        #expect(path[1].split.id == "root")
        #expect(path[1].branch == .second)
    }

    @Test func browserPathToPaneEmptyOnLoneLeaf() {
        #expect(pane("a").browserPathToPane(targetPaneId: "a") == [])
        #expect(pane("a").browserPathToPane(targetPaneId: "z") == nil)
    }

    @Test func browserPathToPaneNilWhenAbsent() {
        let tree = split("root", pane("a"), pane("b"))
        #expect(tree.browserPathToPane(targetPaneId: "z") == nil)
    }

    /// Pane nodes collect depth-first, first child before second.
    @Test func browserCollectPaneNodesDepthFirst() {
        let tree = split("root", pane("a"), split("inner", pane("b"), pane("c")))
        var out: [ExternalPaneNode] = []
        tree.browserCollectPaneNodes(into: &out)
        #expect(out.map(\.id) == ["a", "b", "c"])
    }

    /// A horizontal split divides left/right at the clamped divider; vertical
    /// divides top/bottom.
    @Test func browserCollectNormalizedPaneBoundsHorizontalSplit() {
        let tree = split("root", orientation: "horizontal", divider: 0.3, pane("a"), pane("b"))
        var out: [String: CGRect] = [:]
        tree.browserCollectNormalizedPaneBounds(availableRect: CGRect(x: 0, y: 0, width: 1, height: 1), into: &out)
        #expect(out["a"] == CGRect(x: 0, y: 0, width: 0.3, height: 1))
        #expect(out["b"] == CGRect(x: 0.3, y: 0, width: 0.7, height: 1))
    }

    @Test func browserCollectNormalizedPaneBoundsVerticalSplit() {
        let tree = split("root", orientation: "vertical", divider: 0.25, pane("a"), pane("b"))
        var out: [String: CGRect] = [:]
        tree.browserCollectNormalizedPaneBounds(availableRect: CGRect(x: 0, y: 0, width: 1, height: 1), into: &out)
        #expect(out["a"] == CGRect(x: 0, y: 0, width: 1, height: 0.25))
        #expect(out["b"] == CGRect(x: 0, y: 0.25, width: 1, height: 0.75))
    }

    /// A divider outside 0...1 is clamped before splitting.
    @Test func browserCollectNormalizedPaneBoundsClampsDivider() {
        let tree = split("root", orientation: "horizontal", divider: 1.8, pane("a"), pane("b"))
        var out: [String: CGRect] = [:]
        tree.browserCollectNormalizedPaneBounds(availableRect: CGRect(x: 0, y: 0, width: 1, height: 1), into: &out)
        #expect(out["a"] == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(out["b"] == CGRect(x: 1, y: 0, width: 0, height: 1))
    }
}

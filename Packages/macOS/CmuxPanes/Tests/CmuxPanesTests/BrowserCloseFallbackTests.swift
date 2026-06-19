import CoreGraphics
import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

@Suite struct BrowserCloseFallbackTests {
    private func pane(
        _ id: String,
        x: Double = 0,
        y: Double = 0,
        width: Double = 100,
        height: Double = 100
    ) -> ExternalTreeNode {
        .pane(ExternalPaneNode(
            id: id,
            frame: PixelRect(x: x, y: y, width: width, height: height),
            tabs: [],
            selectedTabId: nil
        ))
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

    /// A lone leaf is no split's direct child, so there is no fallback plan.
    @Test func nilForLoneLeaf() {
        #expect(pane("a").browserCloseFallbackPlan(forPaneId: "a") == nil)
    }

    /// When the target is the first branch of its split, the plan records
    /// insertFirst=true, the split orientation, and the nearest pane in the
    /// sibling subtree as the anchor.
    @Test func firstBranchHorizontalSplit() {
        let aID = UUID()
        let bID = UUID()
        let tree = split(
            "root",
            orientation: "horizontal",
            pane(aID.uuidString),
            pane(bID.uuidString)
        )
        let plan = try! #require(tree.browserCloseFallbackPlan(forPaneId: aID.uuidString))
        #expect(plan.orientation == .horizontal)
        #expect(plan.insertFirst == true)
        #expect(plan.anchorPaneId == bID)
    }

    /// When the target is the second branch, insertFirst is false and the anchor
    /// is resolved in the first subtree.
    @Test func secondBranchVerticalSplit() {
        let aID = UUID()
        let bID = UUID()
        let tree = split(
            "root",
            orientation: "vertical",
            pane(aID.uuidString),
            pane(bID.uuidString)
        )
        let plan = try! #require(tree.browserCloseFallbackPlan(forPaneId: bID.uuidString))
        #expect(plan.orientation == .vertical)
        #expect(plan.insertFirst == false)
        #expect(plan.anchorPaneId == aID)
    }

    /// A non-"vertical" orientation string normalizes to horizontal, matching the
    /// legacy lowercased comparison.
    @Test func orientationNormalizesToHorizontal() {
        let aID = UUID()
        let tree = split(
            "root",
            orientation: "HORIZONTAL",
            pane(aID.uuidString),
            pane(UUID().uuidString)
        )
        let plan = try! #require(tree.browserCloseFallbackPlan(forPaneId: aID.uuidString))
        #expect(plan.orientation == .horizontal)
    }

    /// The recursion descends into nested splits to find the target's direct
    /// parent split.
    @Test func descendsIntoNestedSplit() {
        let aID = UUID()
        let bID = UUID()
        let cID = UUID()
        let tree = split(
            "root",
            pane(aID.uuidString),
            split("inner", pane(bID.uuidString), pane(cID.uuidString))
        )
        let plan = try! #require(tree.browserCloseFallbackPlan(forPaneId: bID.uuidString))
        #expect(plan.insertFirst == true)
        #expect(plan.anchorPaneId == cID)
    }

    /// The anchor is the geometrically nearest pane in the sibling subtree,
    /// chosen by squared center distance.
    @Test func anchorIsNearestPaneByCenterDistance() {
        let aID = UUID()
        let nearID = UUID()
        let farID = UUID()
        // Target pane "a" centered near (50,50); sibling holds a near pane at the
        // same band and a far pane lower down.
        let tree = split(
            "root",
            orientation: "horizontal",
            pane(aID.uuidString, x: 0, y: 0, width: 100, height: 100),
            split(
                "inner",
                orientation: "vertical",
                pane(nearID.uuidString, x: 100, y: 0, width: 100, height: 50),
                pane(farID.uuidString, x: 100, y: 500, width: 100, height: 50)
            )
        )
        let plan = try! #require(tree.browserCloseFallbackPlan(forPaneId: aID.uuidString))
        #expect(plan.anchorPaneId == nearID)
    }

    /// browserNearestPaneId with no target center returns the first pane in
    /// depth-first order.
    @Test func nearestPaneNilTargetReturnsFirst() {
        let firstID = UUID()
        let tree = split(
            "inner",
            pane(firstID.uuidString),
            pane(UUID().uuidString)
        )
        #expect(tree.browserNearestPaneId(targetCenter: nil) == firstID)
    }

    /// An empty pane center reads frame origin + half extent.
    @Test func paneCenterIsFrameMidpoint() {
        guard case .pane(let node) = pane("a", x: 10, y: 20, width: 80, height: 40) else {
            Issue.record("expected pane node")
            return
        }
        let center = node.browserPaneCenter
        #expect(center.x == 50)
        #expect(center.y == 40)
    }
}

import Bonsplit
import CoreGraphics
import Foundation
import Testing
@testable import CmuxPanes

@Suite("SplitGeometry")
struct SplitGeometryTests {
    private func pane(_ id: String, x: Double = 0, y: Double = 0, width: Double = 100, height: Double = 100) -> ExternalTreeNode {
        .pane(ExternalPaneNode(
            id: id,
            frame: PixelRect(x: x, y: y, width: width, height: height),
            tabs: [],
            selectedTabId: nil
        ))
    }

    private func split(
        _ id: UUID,
        orientation: String,
        dividerPosition: Double = 0.5,
        first: ExternalTreeNode,
        second: ExternalTreeNode
    ) -> ExternalTreeNode {
        .split(ExternalSplitNode(
            id: id.uuidString,
            orientation: orientation,
            dividerPosition: dividerPosition,
            first: first,
            second: second
        ))
    }

    // MARK: Equalize planning

    @Test func equalizeWeightsNestedSameOrientationSpans() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            dividerPosition: 0.8,
            first: pane("a"),
            second: split(
                innerId,
                orientation: "horizontal",
                dividerPosition: 0.2,
                first: pane("b"),
                second: pane("c")
            )
        )

        let plan = tree.equalizeDividerPlan()

        #expect(plan.foundSplit)
        #expect(!plan.hadInvalidSplitIds)
        // Children are planned before their parent (legacy post-order).
        #expect(plan.adjustments.map(\.splitId) == [innerId, outerId])
        // Inner split divides its two leaves evenly; the outer divider gives
        // its first child 1 of 3 same-orientation spans.
        #expect(plan.adjustments[0].position == 0.5)
        #expect(abs(plan.adjustments[1].position - (1.0 / 3.0)) < 0.0001)
    }

    @Test func equalizeTreatsCrossOrientationSubtreeAsOneSpan() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            first: pane("a"),
            second: split(
                innerId,
                orientation: "vertical",
                first: pane("b"),
                second: pane("c")
            )
        )

        let plan = tree.equalizeDividerPlan()

        // The vertical subtree counts as a single horizontal span, so the
        // outer divider lands at 1/2.
        #expect(plan.adjustments.first { $0.splitId == outerId }?.position == 0.5)
        #expect(plan.adjustments.first { $0.splitId == innerId }?.position == 0.5)
    }

    @Test func equalizeOrientationFilterSkipsOtherOrientations() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            first: pane("a"),
            second: split(
                innerId,
                orientation: "vertical",
                first: pane("b"),
                second: pane("c")
            )
        )

        let plan = tree.equalizeDividerPlan(orientationFilter: "vertical")

        #expect(plan.foundSplit)
        #expect(plan.adjustments.map(\.splitId) == [innerId])

        let noMatch = pane("solo").equalizeDividerPlan(orientationFilter: "vertical")
        #expect(!noMatch.foundSplit)
        #expect(noMatch.adjustments.isEmpty)
    }

    @Test func equalizeFlagsUnparseableSplitIds() {
        let tree = ExternalTreeNode.split(ExternalSplitNode(
            id: "not-a-uuid",
            orientation: "horizontal",
            dividerPosition: 0.5,
            first: pane("a"),
            second: pane("b")
        ))

        let plan = tree.equalizeDividerPlan()

        #expect(plan.foundSplit)
        #expect(plan.hadInvalidSplitIds)
        #expect(plan.adjustments.isEmpty)
    }

    // MARK: Resize planning

    @Test func resizeMovesControllingDividerByPixelDelta() {
        let splitId = UUID()
        let tree = split(
            splitId,
            orientation: "horizontal",
            dividerPosition: 0.5,
            first: pane("a", x: 0, y: 0, width: 300, height: 400),
            second: pane("b", x: 300, y: 0, width: 300, height: 400)
        )

        // Target the second child; .left controls a divider whose target sits
        // in the second child and moves it toward the first child.
        let adjustment = tree.resizeDividerAdjustment(targetPaneId: "b", direction: .left, amountPixels: 60)

        #expect(adjustment?.splitId == splitId)
        // 60px over a 600px axis = 0.1 delta, signed negative for .left.
        #expect(adjustment.map { abs($0.position - 0.4) < 0.0001 } == true)
    }

    @Test func resizeFallsBackToOppositeEdgeAtOuterBoundaryInEveryDirection() {
        let horizontalId = UUID()
        let horizontal = split(
            horizontalId,
            orientation: "horizontal",
            first: pane("left", width: 300),
            second: pane("right", x: 300, width: 300)
        )
        let verticalId = UUID()
        let vertical = split(
            verticalId,
            orientation: "vertical",
            first: pane("top", width: 600, height: 300),
            second: pane("bottom", y: 300, width: 600, height: 300)
        )

        let cases: [(ExternalTreeNode, UUID, String, ResizeDirection, CGFloat)] = [
            (horizontal, horizontalId, "left", .left, 0.6),
            (horizontal, horizontalId, "right", .right, 0.4),
            (vertical, verticalId, "top", .up, 0.6),
            (vertical, verticalId, "bottom", .down, 0.4),
        ]

        for (tree, splitId, paneId, direction, expectedPosition) in cases {
            let adjustment = tree.resizeDividerAdjustment(
                targetPaneId: paneId,
                direction: direction,
                amountPixels: 60
            )
            #expect(adjustment?.splitId == splitId)
            #expect(adjustment.map { abs($0.position - expectedPosition) < 0.0001 } == true)
        }
    }

    @Test func resizePrefersRequestedEdgeBeforeNearerOppositeEdge() {
        let innerId = UUID()
        let rootId = UUID()
        let inner = split(
            innerId,
            orientation: "horizontal",
            first: pane("a", width: 150),
            second: pane("b", x: 150, width: 150)
        )
        let tree = split(
            rootId,
            orientation: "horizontal",
            first: inner,
            second: pane("c", x: 300, width: 300)
        )

        let adjustment = tree.resizeDividerAdjustment(
            targetPaneId: "b",
            direction: .right,
            amountPixels: 60
        )

        #expect(adjustment?.splitId == rootId)
        #expect(adjustment.map { $0.position > 0.5 } == true)
    }

    @Test func resizeRequiresMatchingOrientationAndKnownPane() {
        let splitId = UUID()
        let tree = split(
            splitId,
            orientation: "horizontal",
            first: pane("a", width: 300),
            second: pane("b", x: 300, width: 300)
        )

        #expect(tree.resizeDividerAdjustment(targetPaneId: "b", direction: .up, amountPixels: 10) == nil)
        #expect(tree.resizeDividerAdjustment(targetPaneId: "zz", direction: .left, amountPixels: 10) == nil)
    }

    @Test func resizePrefersInnermostEnclosingSplit() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            dividerPosition: 0.5,
            first: pane("a", width: 300, height: 400),
            second: split(
                innerId,
                orientation: "horizontal",
                dividerPosition: 0.5,
                first: pane("b", x: 300, width: 150, height: 400),
                second: pane("c", x: 450, width: 150, height: 400)
            )
        )

        // "c" sits in the second child of BOTH splits; the innermost
        // (closest enclosing) candidate wins, matching the legacy order.
        let adjustment = tree.resizeDividerAdjustment(targetPaneId: "c", direction: .left, amountPixels: 30)
        #expect(adjustment?.splitId == innerId)
    }

    @Test func resizeClampsDividerToLegacyBounds() {
        let splitId = UUID()
        let tree = split(
            splitId,
            orientation: "vertical",
            dividerPosition: 0.85,
            first: pane("a", width: 600, height: 200),
            second: pane("b", y: 200, width: 600, height: 200)
        )

        // A huge downward move from 0.85 clamps to 0.9.
        let adjustment = tree.resizeDividerAdjustment(targetPaneId: "a", direction: .down, amountPixels: 400)
        #expect(adjustment?.position == 0.9)
        #expect(adjustment?.requestedFocusedBranchShare.map { $0 > 1 } == true)
        #expect(adjustment?.focusedBranchShare == 0.9)
        #expect(adjustment?.initialFocusedBranchShare == 0.85)
        #expect(adjustment?.focusedBranchIsFirst == true)
        #expect(tree.dividerPosition(forSplitId: splitId) == 0.85)
    }

    @Test func resizePlanAtExistingLimitRecordsNoShareChange() {
        let splitId = UUID()
        let tree = split(
            splitId,
            orientation: "horizontal",
            dividerPosition: 0.9,
            first: pane("a", width: 540),
            second: pane("b", x: 540, width: 60)
        )

        let adjustment = tree.resizeDividerAdjustment(
            targetPaneId: "a",
            direction: .right,
            amountPixels: 20
        )

        #expect(adjustment?.initialFocusedBranchShare == 0.9)
        #expect(adjustment?.focusedBranchShare == 0.9)
        #expect(adjustment?.requestedFocusedBranchShare.map { $0 > 0.9 } == true)
    }

    // MARK: Direction values

    @Test func splitDirectionMapsOrientationAndInsertionSide() {
        #expect(SplitDirection.left.isHorizontal)
        #expect(SplitDirection.right.isHorizontal)
        #expect(!SplitDirection.up.isHorizontal)
        #expect(SplitDirection.left.orientation == .horizontal)
        #expect(SplitDirection.down.orientation == .vertical)
        #expect(SplitDirection.left.insertFirst)
        #expect(SplitDirection.up.insertFirst)
        #expect(!SplitDirection.right.insertFirst)
        #expect(!SplitDirection.down.insertFirst)
    }

    @Test func resizeDirectionMapsSplitAxisAndSign() {
        #expect(ResizeDirection.left.splitOrientation == "horizontal")
        #expect(ResizeDirection.down.splitOrientation == "vertical")
        #expect(ResizeDirection.right.requiresPaneInFirstChild)
        #expect(ResizeDirection.down.requiresPaneInFirstChild)
        #expect(!ResizeDirection.left.requiresPaneInFirstChild)
        #expect(ResizeDirection.right.dividerDeltaSign == 1)
        #expect(ResizeDirection.up.dividerDeltaSign == -1)
    }
}

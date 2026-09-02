import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrImposeTests {
    private func leaf(
        _ paneID: String,
        width: Int = 80,
        height: Int = 24,
        x: Int = 0,
        y: Int = 0
    ) -> RemoteHerdrLayoutNode {
        RemoteHerdrLayoutNode(width: width, height: height, x: x, y: y, content: .pane(paneID))
    }

    private func horizontalSplit() -> RemoteHerdrLayoutNode {
        RemoteHerdrLayoutNode(
            width: 200,
            height: 50,
            x: 0,
            y: 0,
            content: .horizontal([
                leaf("w2:p1", width: 100, height: 50, x: 0, y: 0),
                leaf("w2:p2", width: 99, height: 50, x: 101, y: 0),
            ])
        )
    }

    @Test func dividerFractionUsesTmuxPlusOneCell() {
        #expect(RemoteHerdrImpose.dividerFraction(firstSpan: 100, restSpans: [99]) == 0.5)
        #expect(RemoteHerdrImpose.dividerFraction(firstSpan: 1, restSpans: [1000]) == 0.05)
        #expect(RemoteHerdrImpose.dividerFraction(firstSpan: 1000, restSpans: [1]) == 0.95)
    }

    @Test func planParentNeverExceedsRegion() {
        let parent = RemoteHerdrImpose.regionBoundedPlanParent(
            render: RemoteHerdrImposeSize(width: 900, height: 500),
            region: RemoteHerdrImposeSize(width: 800, height: 400)
        )
        #expect(parent?.width == 800)
        #expect(parent?.height == 400)
    }

    @Test func firstPassRebuildsAndGeometryOnlyKeeps() {
        let node = horizontalSplit()
        #expect(RemoteHerdrImpose.treeAction(previousRendered: nil, rendered: node) == .rebuild)
        let wider = RemoteHerdrLayoutNode(
            width: 400,
            height: 50,
            x: 0,
            y: 0,
            content: .horizontal([
                leaf("w2:p1", width: 200, height: 50, x: 0, y: 0),
                leaf("w2:p2", width: 199, height: 50, x: 201, y: 0),
            ])
        )
        #expect(RemoteHerdrImpose.sameShapeAndPaneIDs(node, wider))
        #expect(RemoteHerdrImpose.treeAction(previousRendered: node, rendered: wider) == .keep)
    }

    @Test func leafExpansionAndRemoval() {
        let expand = RemoteHerdrImpose.treeAction(
            previousRendered: leaf("w2:p1", width: 200, height: 50),
            rendered: horizontalSplit()
        )
        guard case let .expandLeaf(expansion) = expand else {
            Issue.record("expected expandLeaf")
            return
        }
        #expect(expansion.existingPaneID == "w2:p1")
        #expect(expansion.newPaneID == "w2:p2")
        #expect(expansion.orientation == .horizontal)
        #expect(!expansion.insertFirst)
        let remove = RemoteHerdrImpose.treeAction(
            previousRendered: horizontalSplit(),
            rendered: leaf("w2:p1")
        )
        #expect(remove == .removeLeaf(paneID: "w2:p2"))
    }

    @Test func rightAssociatedTernaryAndMetricsExtent() throws {
        let ternary = RemoteHerdrLayoutNode(
            width: 300,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                leaf("a", width: 100, height: 24, x: 0, y: 0),
                leaf("b", width: 100, height: 24, x: 100, y: 0),
                leaf("c", width: 99, height: 24, x: 201, y: 0),
            ])
        )
        let tree = try #require(RemoteHerdrImpose.binaryTree(ternary))
        guard case let .split(_, _, _, first, second) = tree,
              case .leaf(let firstID, _) = first,
              case let .split(_, _, _, innerFirst, innerSecond) = second,
              case .leaf(let b, _) = innerFirst,
              case .leaf(let c, _) = innerSecond
        else {
            Issue.record("expected right-associated ternary")
            return
        }
        #expect(firstID == "a")
        #expect(b == "b")
        #expect(c == "c")
        let measured = try #require(RemoteHerdrImpose.binaryTree(
            horizontalSplit(),
            metrics: RemoteHerdrImposeMetrics(cellWidth: 8, cellHeight: 16, dividerThickness: 4),
            parent: RemoteHerdrImposeSize(width: 800, height: 400)
        ))
        guard case let .split(_, _, firstExtent, _, _) = measured else {
            Issue.record("expected measured split")
            return
        }
        #expect(firstExtent != nil)
        #expect((firstExtent ?? 0) > 0)
        #expect((firstExtent ?? 801) <= 800)
    }

    @Test func dragHoldAndNoopSend() {
        var hold: RemoteHerdrDividerDragHold? = RemoteHerdrImpose.beginDividerDrag(
            splitKey: "split-1",
            axis: .horizontal,
            assignedCells: 40
        )
        hold = RemoteHerdrImpose.resolveDividerHold(
            hold, assignedCells: 50, splitStillExists: true
        )
        #expect(hold != nil)
        hold = RemoteHerdrImpose.resolveDividerHold(
            hold, assignedCells: 40, splitStillExists: true
        )
        #expect(hold == nil)
        let noop = RemoteHerdrImpose.endDividerDrag(
            draggedExtent: 400, axisSpan: 800, totalCells: 100, assignedCells: 50
        )
        #expect(noop.cells == 50)
        #expect(!noop.shouldSend)
        let send = RemoteHerdrImpose.endDividerDrag(
            draggedExtent: 200, axisSpan: 800, totalCells: 100, assignedCells: 50
        )
        #expect(send.cells == 25)
        #expect(send.shouldSend)
    }

    @Test func planFromReconcileRebuilds() throws {
        let window = RemoteHerdrWindow(
            tabID: "w2:t1",
            title: "Build",
            orderIndex: 0,
            layout: horizontalSplit(),
            activePaneID: "w2:p2"
        )
        let (_, result) = RemoteHerdrWindowMirror.apply(window: window, previous: nil)
        let plan = try #require(RemoteHerdrImpose.plan(from: result, title: "Build"))
        #expect(plan.treeAction == .rebuild)
        #expect(plan.focusPaneID == "w2:p2")
        #expect(plan.fractions.count == 1)
        #expect(plan.fractions[0] == 0.5)
    }
}

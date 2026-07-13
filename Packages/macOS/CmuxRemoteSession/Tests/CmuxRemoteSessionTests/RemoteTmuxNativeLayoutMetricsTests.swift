import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite struct RemoteTmuxNativeLayoutMetricsTests {
    private func pane(id: Int = 1) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(
            width: 10,
            height: 10,
            x: 0,
            y: 0,
            content: .pane(id)
        )
    }

    @Test func clientGridClaimsTheGridAGhosttySurfaceActuallyRenders() throws {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: .zero,
            tabBarHeight: 30,
            dividerThickness: 1
        )

        let grid = try #require(metrics.clientGrid(
            layout: pane(),
            contentSize: CGSize(width: 300, height: 300)
        ))

        #expect(grid.columns == 30)
        #expect(grid.rows == 27)
        #expect(metrics.residual(of: pane()) == CGSize(width: 1, height: 31))
    }

    @Test func clientGridLeavesServerOwnedTitleRowsInTheClaim() throws {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: CGSize(width: 2, height: 4),
            tabBarHeight: 30,
            dividerThickness: 2,
            paneTitleRowHeight: 10
        )
        let first = pane()
        let second = pane(id: 2)
        let horizontal = RemoteTmuxLayoutNode(
            width: 21,
            height: 10,
            x: 0,
            y: 0,
            content: .horizontal([first, second])
        )
        let vertical = RemoteTmuxLayoutNode(
            width: 10,
            height: 21,
            x: 0,
            y: 0,
            content: .vertical([first, second])
        )

        let horizontalGrid = try #require(metrics.clientGrid(
            layout: horizontal,
            contentSize: CGSize(width: 296, height: 304)
        ))
        let verticalGrid = try #require(metrics.clientGrid(
            layout: vertical,
            contentSize: CGSize(width: 302, height: 340)
        ))

        #expect(horizontalGrid.columns == 30)
        #expect(horizontalGrid.rows == 27)
        #expect(verticalGrid.columns == 30)
        #expect(verticalGrid.rows == 28)
    }

    @Test func titleRowsOnlyChargePanesTouchingTheirConfiguredEdge() {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: CGSize(width: 2, height: 4),
            tabBarHeight: 30,
            dividerThickness: 2,
            paneTitleRowHeight: 10
        )
        let topTitleLayout = RemoteTmuxLayoutNode(
            width: 10,
            height: 21,
            x: 0,
            y: 0,
            content: .vertical([
                RemoteTmuxLayoutNode(width: 10, height: 9, x: 0, y: 1, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 10, height: 10, x: 0, y: 11, content: .pane(2)),
            ])
        )
        let bottomTitleLayout = RemoteTmuxLayoutNode(
            width: 10,
            height: 21,
            x: 0,
            y: 0,
            content: .vertical([
                RemoteTmuxLayoutNode(width: 10, height: 10, x: 0, y: 0, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 10, height: 9, x: 0, y: 11, content: .pane(2)),
            ])
        )

        #expect(metrics.residual(of: topTitleLayout).height == 72)
        #expect(metrics.residual(of: bottomTitleLayout).height == 72)
        #expect(RemoteTmuxPaneTitleRowPlacement.top.paneIDs(in: topTitleLayout) == [1])
        #expect(RemoteTmuxPaneTitleRowPlacement.bottom.paneIDs(in: bottomTitleLayout) == [2])
        #expect(RemoteTmuxNativeMeasuredSplitTree(
            tree: RemoteTmuxNativeSplitTree(layout: topTitleLayout),
            metrics: metrics
        ).residual.height == 72)
        #expect(RemoteTmuxNativeMeasuredSplitTree(
            tree: RemoteTmuxNativeSplitTree(layout: bottomTitleLayout),
            metrics: metrics
        ).residual.height == 72)
    }

    @Test func dragConversionsSubtractChromeButNotPlacementSlack() {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: CGSize(width: 2, height: 4),
            tabBarHeight: 30,
            dividerThickness: 2,
            paneTitleRowHeight: 10
        )
        let leaf = pane()
        let measured = RemoteTmuxNativeMeasuredSplitTree(
            tree: RemoteTmuxNativeSplitTree(layout: leaf),
            metrics: metrics
        )

        #expect(metrics.requestedTmuxSpan(
            first: leaf,
            orientation: .horizontal,
            parentExtent: 99,
            dividerPosition: 1
        ) == 10)
        #expect(metrics.requestedTmuxSpan(
            first: measured,
            orientation: .horizontal,
            parentExtent: 99,
            dividerPosition: 1
        ) == 10)
        #expect(metrics.requestedTmuxSpan(
            pane: leaf,
            orientation: .horizontal,
            outerExtent: 97
        ) == 10)
        #expect(metrics.requestedTmuxSpan(
            first: measured,
            orientation: .vertical,
            parentExtent: 141,
            dividerPosition: 1
        ) == 10)
    }

    @Test func plannerDoesNotSpendAssignedCellsOnPlacementSlack() throws {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: .zero,
            tabBarHeight: 0,
            dividerThickness: 1
        )
        let first = RemoteTmuxLayoutNode(
            width: 90, height: 24, x: 0, y: 0, content: .pane(1)
        )
        let second = RemoteTmuxLayoutNode(
            width: 10, height: 24, x: 91, y: 0, content: .pane(2)
        )
        let layout = RemoteTmuxLayoutNode(
            width: 101,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([first, second])
        )
        let container = CGSize(width: 1_001, height: 240)
        let claim = try #require(metrics.clientGrid(layout: layout, contentSize: container))
        #expect(claim.columns == 101)

        let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
        let plan = planner.plan(
            tree: RemoteTmuxNativeMeasuredSplitTree(
                tree: RemoteTmuxNativeSplitTree(layout: layout), metrics: metrics
            ),
            parentSize: container
        )
        let outerSizes = planner.outerSizes(of: plan)
        let firstOuter = try #require(outerSizes[1])
        let secondOuter = try #require(outerSizes[2])

        #expect(Int(floor(firstOuter.width / metrics.cellSize.width)) >= first.width)
        #expect(Int(floor(secondOuter.width / metrics.cellSize.width)) >= second.width)
    }
}

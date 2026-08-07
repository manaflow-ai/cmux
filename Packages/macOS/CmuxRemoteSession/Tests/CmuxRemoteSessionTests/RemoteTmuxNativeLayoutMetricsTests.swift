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

        // The claim charges the per-pane rail slack too: 300pt is EXACTLY
        // 30 cells with zero chrome, and a slack-free claim at that boundary
        // is the one the whole-point rails cannot always honor (the
        // tight-container fuzz measures the dropped cell). One point per
        // pane buys honest placement for every claimed cell.
        #expect(grid.columns == 29)
        #expect(grid.rows == 26)
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

        // One rail-slack point per pane comes off the claim (see the
        // single-pane claim test). The claim also RESERVES the one server-owned
        // title row at the configured window edge (`pane-border-status`): the
        // window needs that extra row to draw the border title on top of the
        // panes, so the claim carries a row for it whether or not the current
        // spans happen to fold it into a child — one more row than the panes
        // alone would occupy. Height overhead is therefore one cell smaller
        // than the panes-only chrome (horizontal 35 − 10 = 25, vertical 62 − 10
        // = 52), lifting each claim by a row (rows 26 → 27, 27 → 28).
        #expect(horizontalGrid.columns == 29)
        #expect(horizontalGrid.rows == 27)
        #expect(verticalGrid.columns == 29)
        #expect(verticalGrid.rows == 28)
    }

    @Test func clientGridClaimIsAFixedPointRegardlessOfTitleRowFolding() throws {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: CGSize(width: 2, height: 4),
            tabBarHeight: 30,
            dividerThickness: 2,
            paneTitleRowHeight: 10
        )
        // One window, two ways tmux publishes it under pane-border-status. The
        // spans differ only in whether the title row shows as an extra gap row
        // (parent taller than the children) or is folded so the children sum to
        // the parent — the reflow flips between these live-to-live. The claim is
        // a function of the container, cell size, structure, and border-status
        // setting, so it MUST NOT move with that fold, or it chases its own
        // effect and the window-size claim never settles.
        let titleInGap = RemoteTmuxLayoutNode(
            width: 10,
            height: 22,
            x: 0,
            y: 0,
            content: .vertical([
                RemoteTmuxLayoutNode(width: 10, height: 10, x: 0, y: 1, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 10, height: 10, x: 0, y: 12, content: .pane(2)),
            ])
        )
        let titleFolded = RemoteTmuxLayoutNode(
            width: 10,
            height: 21,
            x: 0,
            y: 0,
            content: .vertical([
                RemoteTmuxLayoutNode(width: 10, height: 10, x: 0, y: 0, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 10, height: 10, x: 0, y: 11, content: .pane(2)),
            ])
        )
        let container = CGSize(width: 302, height: 340)
        let gapClaim = try #require(metrics.clientGrid(layout: titleInGap, contentSize: container))
        let foldedClaim = try #require(metrics.clientGrid(layout: titleFolded, contentSize: container))
        #expect(gapClaim.columns == foldedClaim.columns)
        #expect(gapClaim.rows == foldedClaim.rows)
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

        // Title rows live in the tree's COORDINATES — the interior gap and
        // the window-edge row — and cost the native render nothing: the fold
        // credits the actual gap cells (21 span − 19 pane rows = 2) instead
        // of charging any pane a native title row nothing renders. Chrome is
        // 2×(tabBar 30 + pad 4 + slack 1) + divider 2 − 2 gap cells ×10 = 52.
        #expect(metrics.residual(of: topTitleLayout).height == 52)
        #expect(metrics.residual(of: bottomTitleLayout).height == 52)
        #expect(RemoteTmuxPaneTitleRowPlacement.top.paneIDs(in: topTitleLayout) == [1])
        #expect(RemoteTmuxPaneTitleRowPlacement.bottom.paneIDs(in: bottomTitleLayout) == [2])
        // The binary measured fold must agree with the n-ary fold exactly.
        #expect(RemoteTmuxNativeMeasuredSplitTree(
            tree: RemoteTmuxNativeSplitTree(layout: topTitleLayout),
            metrics: metrics
        ).residual.height == metrics.residual(of: topTitleLayout).height)
        #expect(RemoteTmuxNativeMeasuredSplitTree(
            tree: RemoteTmuxNativeSplitTree(layout: bottomTitleLayout),
            metrics: metrics
        ).residual.height == metrics.residual(of: bottomTitleLayout).height)
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
        // Vertical chrome for a lone pane is tabBar + pad only — tmux's
        // title row costs the native render nothing, so 141 − 2 divider
        // leaves 139 − 34 = 105pt of grid → 10.5 → 11 cells requested.
        #expect(metrics.requestedTmuxSpan(
            first: measured,
            orientation: .vertical,
            parentExtent: 141,
            dividerPosition: 1
        ) == 11)
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
        let container = CGSize(width: 1_003, height: 240)
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

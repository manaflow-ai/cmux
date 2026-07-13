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
}

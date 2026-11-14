import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceOwnedBarStatusBandTests {
    private let barHeight: CGFloat = 50

    @Test func cornerOwningTheWholeBandRaisesTheBarClearOfTheCorner() {
        let band = WorkspaceOwnedBarStatusBand.placement(
            topInset: 82,
            topTrailingCorner: CGSize(width: 130, height: 82),
            barHeight: barHeight
        )

        #expect(band == WorkspaceOwnedBarStatusBand(raise: 50, trailingClearance: 130))
    }

    @Test func fullWidthStatusBarKeepsTheBarBelowTheSafeArea() {
        // A notch or Dynamic Island reports no corner region.
        let band = WorkspaceOwnedBarStatusBand.placement(
            topInset: 59,
            topTrailingCorner: .zero,
            barHeight: barHeight
        )

        #expect(band == .none)
    }

    @Test func cornerShorterThanTheBandKeepsTheBarBelowTheSafeArea() {
        // Something other than the trailing corner owns part of the top edge.
        let band = WorkspaceOwnedBarStatusBand.placement(
            topInset: 82,
            topTrailingCorner: CGSize(width: 130, height: 40),
            barHeight: barHeight
        )

        #expect(band == .none)
    }

    @Test func bandShorterThanTheBarKeepsTheBarBelowTheSafeArea() {
        // Landscape on the Duo moves the indicators to the trailing edge.
        let band = WorkspaceOwnedBarStatusBand.placement(
            topInset: 24,
            topTrailingCorner: CGSize(width: 84, height: 24),
            barHeight: barHeight
        )

        #expect(band == .none)
    }

    @Test func sidebarRowBelowTheSafeAreaLowersTheBarOntoTheRow() {
        // Duo landscape: no top inset; the sidebar toggle spans y 26...70.
        let band = WorkspaceOwnedBarStatusBand.aligned(
            withSidebarRow: CGRect(x: 16, y: 26, width: 44, height: 44),
            container: WorkspaceOwnedBarContainerTop(barTop: 0, topInset: 0, topTrailingCorner: .zero),
            barHeight: 54
        )

        #expect(band == WorkspaceOwnedBarStatusBand(raise: -21, trailingClearance: 0, controlOutset: 2))
    }

    @Test func sidebarRowInsideTheStatusBandKeepsTheBarBelowIt() {
        // Duo portrait: the sidebar row sits in the 82 pt band beside the
        // corner content, so the detail bar stays below the safe area.
        let band = WorkspaceOwnedBarStatusBand.aligned(
            withSidebarRow: CGRect(x: 16, y: 26, width: 44, height: 44),
            container: WorkspaceOwnedBarContainerTop(
                barTop: 82,
                topInset: 82,
                topTrailingCorner: CGSize(width: 144, height: 82)
            ),
            barHeight: 54
        )

        #expect(band == nil)
    }

    @Test func unmeasuredSidebarRowLeavesTheBarInPlace() {
        let band = WorkspaceOwnedBarStatusBand.aligned(
            withSidebarRow: .zero,
            container: .zero,
            barHeight: 54
        )

        #expect(band == nil)
    }
}

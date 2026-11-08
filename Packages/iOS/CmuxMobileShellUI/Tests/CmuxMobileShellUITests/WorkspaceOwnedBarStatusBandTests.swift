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
}

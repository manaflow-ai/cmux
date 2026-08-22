import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileLeadingToolbarTitleWidthTests {
    private func cap(
        _ contentWidth: CGFloat,
        hasBackButton: Bool = true,
        hasTrailingCluster: Bool = true,
        hasChatToggle: Bool = true
    ) -> CGFloat {
        MobileLeadingToolbarTitleWidth(
            contentWidth: contentWidth,
            hasBackButton: hasBackButton,
            hasTrailingCluster: hasTrailingCluster,
            hasChatToggle: hasChatToggle
        ).cap
    }

    @Test func unmeasuredReturnsFallback() {
        #expect(cap(0) == MobileLeadingToolbarTitleWidth.unmeasuredFallback)
    }

    @Test func leadingTitleReservesBackAndTrailingControls() {
        let expected = 393
            - MobileLeadingToolbarTitleWidth.backButtonReserve
            - MobileLeadingToolbarTitleWidth.trailingReserveBase
            - MobileLeadingToolbarTitleWidth.chatToggleReserve
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing

        #expect(cap(393) == expected)
    }

    @Test func titleGainsRoomWithoutChatToggle() {
        #expect(cap(260, hasChatToggle: false) > cap(260, hasChatToggle: true))
    }

    @Test func titleGainsRoomWithoutBackButton() {
        #expect(cap(260, hasBackButton: false) > cap(260, hasBackButton: true))
    }

    @Test func noTrailingClusterDoesNotReserveChatToggle() {
        let contentWidth: CGFloat = 220
        let withoutTrailing = cap(contentWidth, hasTrailingCluster: false)
        let expected = contentWidth
            - MobileLeadingToolbarTitleWidth.backButtonReserve
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing

        #expect(withoutTrailing == expected)
    }

    @Test func measuredWidthUsesAllRemainingSpace() {
        let expected: CGFloat = 800
            - MobileLeadingToolbarTitleWidth.backButtonReserve
            - MobileLeadingToolbarTitleWidth.trailingReserveBase
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing

        #expect(cap(800, hasChatToggle: false) == expected)
    }

    @Test func measuredTrailingItemsReplaceTheConstantEstimate() {
        let measured = MobileLeadingToolbarTitleWidth(
            contentWidth: 393,
            hasBackButton: true,
            hasTrailingCluster: true,
            hasChatToggle: true,
            measuredTrailingItemsWidth: 150,
            measuredTrailingItemCount: 2,
            trailingItemCount: 2
        )
        let expected: CGFloat = 393
            - MobileLeadingToolbarTitleWidth.backButtonReserve
            - (150 + 2 * MobileLeadingToolbarTitleWidth.trailingItemChrome)
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing

        #expect(measured.cap == max(0, expected))
    }

    @Test func wideMeasuredTrailingItemsShrinkTheTitleInsteadOfOverflowing() {
        // A changes chip plus picker plus chat toggle wider than the constant
        // estimate must shrink the title cap, not push items into More.
        let constantOnly = cap(393)
        let measured = MobileLeadingToolbarTitleWidth(
            contentWidth: 393,
            hasBackButton: true,
            hasTrailingCluster: true,
            hasChatToggle: true,
            measuredTrailingItemsWidth: 200,
            measuredTrailingItemCount: 3,
            trailingItemCount: 3
        )

        #expect(measured.cap < constantOnly)
    }

    @Test func zeroMeasurementFallsBackToConstants() {
        let unmeasured = MobileLeadingToolbarTitleWidth(
            contentWidth: 393,
            hasBackButton: true,
            hasTrailingCluster: true,
            hasChatToggle: true,
            measuredTrailingItemsWidth: 0,
            measuredTrailingItemCount: 0,
            trailingItemCount: 1
        )

        #expect(unmeasured.cap == cap(393))
    }

    @Test func structuralItemWithoutMeasurementStillReservesSpace() {
        // The changes chip just appeared: the cluster has measured, the chip
        // has not. The cap must not expand into the chip's space, or the
        // system bounces it into the More menu.
        let clusterOnly = MobileLeadingToolbarTitleWidth(
            contentWidth: 393,
            hasBackButton: true,
            hasTrailingCluster: true,
            hasChatToggle: true,
            measuredTrailingItemsWidth: 90,
            measuredTrailingItemCount: 1,
            trailingItemCount: 1
        )
        let clusterPlusUnmeasuredChip = MobileLeadingToolbarTitleWidth(
            contentWidth: 393,
            hasBackButton: true,
            hasTrailingCluster: true,
            hasChatToggle: true,
            measuredTrailingItemsWidth: 90,
            measuredTrailingItemCount: 1,
            trailingItemCount: 2
        )

        let reserveDelta = clusterOnly.cap - clusterPlusUnmeasuredChip.cap
        #expect(reserveDelta
            >= MobileLeadingToolbarTitleWidth.unmeasuredTrailingItemReserve)
    }
}

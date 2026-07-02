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
        let expected = min(
            MobileLeadingToolbarTitleWidth.maximumMeasuredCap,
            393
            - MobileLeadingToolbarTitleWidth.backButtonReserve
            - MobileLeadingToolbarTitleWidth.trailingReserveBase
            - MobileLeadingToolbarTitleWidth.chatToggleReserve
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing
        )

        #expect(cap(393) == expected)
    }

    @Test func titleGainsRoomWithoutChatToggle() {
        #expect(cap(260, hasChatToggle: false) > cap(260, hasChatToggle: true))
    }

    @Test func iPhoneWidthCapsTitleBeforeTrailingControlsOverflow() {
        #expect(cap(393, hasChatToggle: true) <= 140)
        #expect(cap(393, hasChatToggle: false) <= MobileLeadingToolbarTitleWidth.maximumMeasuredCap)
    }

    @Test func titleGainsRoomWithoutBackButton() {
        #expect(cap(260, hasBackButton: false) > cap(260, hasBackButton: true))
    }

    @Test func noTrailingClusterDoesNotReserveChatToggle() {
        let withoutTrailing = cap(393, hasTrailingCluster: false)
        let expected = min(
            MobileLeadingToolbarTitleWidth.maximumMeasuredCap,
            393
            - MobileLeadingToolbarTitleWidth.backButtonReserve
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing
        )

        #expect(withoutTrailing == expected)
    }

    @Test func measuredWidthDoesNotExpandPastInitialFallback() {
        #expect(cap(800, hasChatToggle: false) == MobileLeadingToolbarTitleWidth.unmeasuredFallback)
    }
}

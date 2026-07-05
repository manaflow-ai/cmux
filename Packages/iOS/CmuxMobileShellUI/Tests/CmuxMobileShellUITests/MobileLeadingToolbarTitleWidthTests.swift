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
            - MobileLeadingToolbarTitleWidth.newTerminalReserve
            - MobileLeadingToolbarTitleWidth.chatToggleReserve
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing
        )

        #expect(cap(393) == expected)
    }

    @Test func titleGainsRoomWithoutChatToggle() {
        #expect(cap(260, hasChatToggle: false) > cap(260, hasChatToggle: true))
    }

    @Test func iPhoneWidthCapsTitleBeforeTrailingControlsOverflow() {
        let expectedWithChat = 393
            - MobileLeadingToolbarTitleWidth.backButtonReserve
            - MobileLeadingToolbarTitleWidth.trailingReserveBase
            - MobileLeadingToolbarTitleWidth.newTerminalReserve
            - MobileLeadingToolbarTitleWidth.chatToggleReserve
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing

        #expect(cap(393, hasChatToggle: true) == expectedWithChat)
        #expect(cap(393, hasChatToggle: false) == 140)
    }

    @Test func titleGainsRoomWithoutBackButton() {
        #expect(cap(320, hasBackButton: false) > cap(320, hasBackButton: true))
    }

    @Test func noTrailingClusterDoesNotReserveChatToggle() {
        let contentWidth: CGFloat = 220
        let withoutTrailing = cap(contentWidth, hasTrailingCluster: false)
        let expected = min(
            MobileLeadingToolbarTitleWidth.maximumMeasuredCap,
            contentWidth
            - MobileLeadingToolbarTitleWidth.backButtonReserve
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing
        )

        #expect(withoutTrailing == expected)
    }

    @Test func measuredWidthDoesNotExpandPastInitialFallback() {
        #expect(cap(800, hasChatToggle: false) == MobileLeadingToolbarTitleWidth.unmeasuredFallback)
    }
}

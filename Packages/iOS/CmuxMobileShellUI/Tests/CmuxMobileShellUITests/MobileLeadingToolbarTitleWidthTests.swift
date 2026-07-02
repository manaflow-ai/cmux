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
        #expect(cap(393, hasChatToggle: false) > cap(393, hasChatToggle: true))
    }

    @Test func titleGainsRoomWithoutBackButton() {
        #expect(cap(393, hasBackButton: false) > cap(393, hasBackButton: true))
    }

    @Test func noTrailingClusterDoesNotReserveChatToggle() {
        let withoutTrailing = cap(393, hasTrailingCluster: false)
        let expected = 393
            - MobileLeadingToolbarTitleWidth.backButtonReserve
            - MobileLeadingToolbarTitleWidth.barMarginsAndSpacing

        #expect(withoutTrailing == expected)
    }
}

import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileNavTitleWidthTests {
    private func cap(
        _ contentWidth: CGFloat,
        hasBackButton: Bool = true,
        hasTrailingCluster: Bool = true,
        hasChatToggle: Bool = true
    ) -> CGFloat {
        MobileNavTitleWidth(
            contentWidth: contentWidth,
            hasBackButton: hasBackButton,
            hasTrailingCluster: hasTrailingCluster,
            hasChatToggle: hasChatToggle
        ).cap
    }

    @Test func unmeasuredReturnsFallback() {
        #expect(cap(0) == MobileNavTitleWidth.unmeasuredFallback)
    }

    @Test func growsWithPaneWidth() {
        let narrow = cap(320)
        let wide = cap(1024)
        #expect(wide > narrow)
    }

    @Test func moreRoomWithoutChatToggle() {
        let withToggle = cap(393)
        let withoutToggle = cap(393, hasChatToggle: false)
        #expect(withoutToggle > withToggle)
    }

    @Test func measuredCapNeverExceedsSafeCenteredSlot() {
        let trailing = MobileNavTitleWidth.trailingReserveBase + MobileNavTitleWidth.chatToggleReserve
        #expect(cap(320) == 320 - 2 * trailing)
    }

    @Test func moreRoomWithoutBackButton() {
        let withBack = cap(393, hasChatToggle: false)
        let withoutBack = cap(393, hasBackButton: false, hasChatToggle: false)
        #expect(withoutBack > withBack)
    }

    @Test func centeredCapReservesWiderSideSymmetrically() {
        let measured = cap(393)
        let expected = 393 - 2 * max(
            MobileNavTitleWidth.leadingReserve,
            MobileNavTitleWidth.trailingReserveBase + MobileNavTitleWidth.chatToggleReserve
        )
        #expect(measured == expected)
    }

    /// The whole point of the change: the old flat 300pt reserve left only ~93pt
    /// of title on a 393pt phone. The tight reserve must give a long title
    /// noticeably more room, even with the chat toggle present.
    @Test func growsMoreThanLegacyFlatReserve() {
        let measured = cap(393)
        #expect(measured > 393 - 300)
    }

    @Test func noTrailingClusterDoesNotReserveChatToggle() {
        let withTrailing = cap(393)
        let withoutTrailing = cap(393, hasTrailingCluster: false)

        #expect(withoutTrailing == 393 - 2 * MobileNavTitleWidth.leadingReserve)
        #expect(withoutTrailing > withTrailing)
    }

    @Test func noSideClustersCanUseMeasuredWidth() {
        #expect(cap(393, hasBackButton: false, hasTrailingCluster: false) == 393)
    }
}

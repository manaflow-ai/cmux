import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileNavTitleWidthTests {
    @Test func unmeasuredReturnsFallback() {
        #expect(
            MobileNavTitleWidth(contentWidth: 0, hasBackButton: true, hasChatToggle: true).leadingCap
                == MobileNavTitleWidth.unmeasuredFallback
        )
    }

    @Test func growsWithPaneWidth() {
        let narrow = MobileNavTitleWidth(contentWidth: 320, hasBackButton: true, hasChatToggle: true).leadingCap
        let wide = MobileNavTitleWidth(contentWidth: 1024, hasBackButton: true, hasChatToggle: true).leadingCap
        #expect(wide > narrow)
    }

    @Test func moreRoomWithoutChatToggle() {
        let withToggle = MobileNavTitleWidth(contentWidth: 393, hasBackButton: true, hasChatToggle: true).leadingCap
        let withoutToggle = MobileNavTitleWidth(contentWidth: 393, hasBackButton: true, hasChatToggle: false).leadingCap
        #expect(withoutToggle > withToggle)
    }

    @Test func neverBelowFloor() {
        #expect(
            MobileNavTitleWidth(contentWidth: 120, hasBackButton: true, hasChatToggle: true).leadingCap
                == MobileNavTitleWidth.floor
        )
    }

    @Test func moreRoomWithoutBackButton() {
        let withBack = MobileNavTitleWidth(contentWidth: 393, hasBackButton: true, hasChatToggle: false).leadingCap
        let withoutBack = MobileNavTitleWidth(contentWidth: 393, hasBackButton: false, hasChatToggle: false).leadingCap
        #expect(withoutBack > withBack)
    }

    /// The whole point of the change: the old flat 300pt reserve left only ~93pt
    /// of title on a 393pt phone. The tight reserve must give a long title
    /// noticeably more room, even with the chat toggle present.
    @Test func growsMoreThanLegacyFlatReserve() {
        let cap = MobileNavTitleWidth(contentWidth: 393, hasBackButton: true, hasChatToggle: true).leadingCap
        #expect(cap > 393 - 300)
    }
}

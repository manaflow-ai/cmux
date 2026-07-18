import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileNavTitleWidthTests {
    @Test func unmeasuredReturnsFallback() {
        #expect(
            MobileNavTitleWidth.cap(contentWidth: 0, hasChatToggle: true)
                == MobileNavTitleWidth.unmeasuredFallback
        )
    }

    @Test func growsWithPaneWidth() {
        let narrow = MobileNavTitleWidth.cap(contentWidth: 320, hasChatToggle: true)
        let wide = MobileNavTitleWidth.cap(contentWidth: 1024, hasChatToggle: true)
        #expect(wide > narrow)
    }

    @Test func moreRoomWithoutChatToggle() {
        let withToggle = MobileNavTitleWidth.cap(contentWidth: 393, hasChatToggle: true)
        let withoutToggle = MobileNavTitleWidth.cap(contentWidth: 393, hasChatToggle: false)
        #expect(withoutToggle > withToggle)
    }

    @Test func neverBelowFloor() {
        #expect(
            MobileNavTitleWidth.cap(contentWidth: 120, hasChatToggle: true)
                == MobileNavTitleWidth.floor
        )
    }

    /// The whole point of the change: the old flat 300pt reserve left only ~93pt
    /// of title on a 393pt phone. The tight reserve must give a long title
    /// noticeably more room, even with the chat toggle present.
    @Test func growsMoreThanLegacyFlatReserve() {
        let cap = MobileNavTitleWidth.cap(contentWidth: 393, hasChatToggle: true)
        #expect(cap > 393 - 300)
    }
}

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

    @Test func reservesOverviewButtonWithoutChatToggle() {
        let cap = MobileNavTitleWidth.cap(contentWidth: 393, hasChatToggle: false)
        let trailing = MobileNavTitleWidth.trailingReserveBase + MobileNavTitleWidth.terminalOverviewReserve
        #expect(cap == 393 - 2 * max(MobileNavTitleWidth.leadingReserve, trailing))
    }

    @Test func chatToggleDoesNotExceedAvailableGap() {
        let cap = MobileNavTitleWidth.cap(contentWidth: 393, hasChatToggle: true)
        let trailing = MobileNavTitleWidth.trailingReserveBase
            + MobileNavTitleWidth.terminalOverviewReserve
            + MobileNavTitleWidth.chatToggleReserve
        #expect(cap == 393 - 2 * max(MobileNavTitleWidth.leadingReserve, trailing))
    }

    @Test func returnsZeroWhenSideClustersLeaveNoCenterGap() {
        #expect(MobileNavTitleWidth.cap(contentWidth: 120, hasChatToggle: true) == 0)
    }

    /// The old flat 300pt reserve left only ~93pt of title on a 393pt phone.
    /// Without the chat toggle, the measured reserve still gives long titles
    /// noticeably more room while keeping clear of the overview + picker buttons.
    @Test func growsMoreThanLegacyFlatReserve() {
        let cap = MobileNavTitleWidth.cap(contentWidth: 393, hasChatToggle: false)
        #expect(cap > 393 - 300)
    }
}

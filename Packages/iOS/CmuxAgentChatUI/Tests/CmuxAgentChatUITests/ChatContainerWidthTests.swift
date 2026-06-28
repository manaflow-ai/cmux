import CoreGraphics
import Testing

@testable import CmuxAgentChatUI

@Suite("ChatContainerWidth")
struct ChatContainerWidthTests {
    @Test("resolved table bounds width is used directly")
    func usesBoundsWidth() {
        let width = ChatContainerWidth(
            boundsWidth: 390,
            windowWidth: 430,
            screenWidth: 440
        ).effectiveWidth
        #expect(width == 390)
    }

    // Regression: on a freshly-inserted pending row's first layout pass the
    // table bounds width is still 0. Without a fallback the bubble cap resolves
    // to .infinity and the bubble renders full-width before snapping to fit.
    // The hosting window width must stand in so the cap is correct on the
    // first render.
    @Test("falls back to the window width before the table bounds resolve")
    func fallsBackToWindowWidth() {
        let width = ChatContainerWidth(
            boundsWidth: 0,
            windowWidth: 430,
            screenWidth: 440
        ).effectiveWidth
        #expect(width == 430)
    }

    @Test("falls back to the screen width when there is no window yet")
    func fallsBackToScreenWidth() {
        let width = ChatContainerWidth(
            boundsWidth: 0,
            windowWidth: nil,
            screenWidth: 440
        ).effectiveWidth
        #expect(width == 440)
    }

    @Test("a zero window width is skipped in favor of the screen width")
    func skipsZeroWindowWidth() {
        let width = ChatContainerWidth(
            boundsWidth: 0,
            windowWidth: 0,
            screenWidth: 440
        ).effectiveWidth
        #expect(width == 440)
    }

    @Test("returns zero only when no width is known")
    func returnsZeroWhenNothingKnown() {
        let width = ChatContainerWidth(
            boundsWidth: 0,
            windowWidth: nil,
            screenWidth: nil
        ).effectiveWidth
        #expect(width == 0)
    }
}

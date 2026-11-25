import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// A page landing restores the reader's anchor by writing the offset. While
/// the scroll indicator is scrubbed, UIKit sets the offset from the thumb's
/// place on every move, so that write was undone and the rows jumped by the
/// page's height (phone, iOS 26.4: two pages landed at offset -592 while the
/// thumb was dragged past the top; content grew 6271 and 4793 pt and the
/// offset moved 3 pt). The page waits for the scrub instead.
@Suite struct ConversationPageLandingTests {
    @Test func aScrubbedIndicatorHoldsThePage() {
        // The scrub reports tracking and decelerating together throughout
        // (phone probe: 36 frames, the offset 8107 -> -590).
        #expect(ConversationPageLanding.waits(isTracking: true, isDecelerating: true, offsetY: 4000, topInset: 157))
    }

    @Test func aFingerPullingPastTheTopHoldsThePage() {
        #expect(ConversationPageLanding.waits(isTracking: true, isDecelerating: false, offsetY: -592, topInset: 157))
        #expect(ConversationPageLanding.waits(isTracking: true, isDecelerating: false, offsetY: -158, topInset: 157))
    }

    @Test func anOrdinaryDragLandsThePageUnderTheFinger() {
        #expect(!ConversationPageLanding.waits(isTracking: true, isDecelerating: false, offsetY: 900, topInset: 157))
        #expect(!ConversationPageLanding.waits(isTracking: true, isDecelerating: false, offsetY: -157, topInset: 157))
    }

    @Test func withoutAFingerThePageLandsAtOnce() {
        // A fling, its bounce back from past the top, or rest.
        #expect(!ConversationPageLanding.waits(isTracking: false, isDecelerating: true, offsetY: 3000, topInset: 157))
        #expect(!ConversationPageLanding.waits(isTracking: false, isDecelerating: true, offsetY: -597, topInset: 157))
        #expect(!ConversationPageLanding.waits(isTracking: false, isDecelerating: false, offsetY: -157, topInset: 157))
    }
}

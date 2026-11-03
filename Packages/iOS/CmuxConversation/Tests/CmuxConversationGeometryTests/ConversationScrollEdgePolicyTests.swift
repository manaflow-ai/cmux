import CmuxConversationGeometry
import CoreGraphics
import Testing

/// The bottom soft scroll edge shows only while transcript content lies
/// under the composer band. At rest on the newest message nothing is under
/// it, so the pocket draws nothing, yet a live pocket makes Core Animation
/// redraw most of the screen on every frame of a typing indicator or text
/// effect (measured: 88% dirty area, 78 offscreen passes per frame).
@Suite struct ConversationScrollEdgePolicyTests {
    /// A 900 pt viewport with an 80 pt composer band, 5000 pt of content.
    let viewport: CGFloat = 900
    let band: CGFloat = 80
    let content: CGFloat = 5000
    var restingOffset: CGFloat { content + band - viewport }

    @Test func restingOnTheNewestMessageHidesTheBottomEdge() {
        #expect(!ConversationScrollEdgePolicy.contentUnderBottomBar(contentHeight: content, offsetY: restingOffset, viewportHeight: viewport, bottomInset: band))
    }

    @Test func pullingPastTheBottomKeepsItHidden() {
        #expect(!ConversationScrollEdgePolicy.contentUnderBottomBar(contentHeight: content, offsetY: restingOffset + 40, viewportHeight: viewport, bottomInset: band))
    }

    @Test func anyScrollUpShowsItAtOnce() {
        #expect(ConversationScrollEdgePolicy.contentUnderBottomBar(contentHeight: content, offsetY: restingOffset - 1, viewportHeight: viewport, bottomInset: band))
        #expect(ConversationScrollEdgePolicy.contentUnderBottomBar(contentHeight: content, offsetY: 0, viewportHeight: viewport, bottomInset: band))
    }

    /// Layout rounding at rest (a fraction of a pixel) does not count.
    @Test func subPixelRoundingAtRestStaysHidden() {
        #expect(!ConversationScrollEdgePolicy.contentUnderBottomBar(contentHeight: content, offsetY: restingOffset - 0.3, viewportHeight: viewport, bottomInset: band))
    }

    /// A short conversation never reaches the composer.
    @Test func shortContentNeverReachesTheBand() {
        #expect(!ConversationScrollEdgePolicy.contentUnderBottomBar(contentHeight: 300, offsetY: -150, viewportHeight: viewport, bottomInset: band))
    }
}

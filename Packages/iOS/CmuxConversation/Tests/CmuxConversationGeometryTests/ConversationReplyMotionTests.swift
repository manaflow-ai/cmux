import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// Values from ChatKit on iOS 26.5 and 27.0 (`CKBalloonSwipeController`,
/// `CKUIBehavior`, the inline-reply layout dynamics) and from frames of
/// Messages recorded on both simulators.
@Suite struct ConversationReplyMotionTests {
    @Test func bubbleFollowsTheFingerThenLogarithmically() {
        #expect(ConversationReplyMotion.bubbleOffset(forTranslation: -5) == 0)
        #expect(ConversationReplyMotion.bubbleOffset(forTranslation: 30) == 30)
        #expect(ConversationReplyMotion.bubbleOffset(forTranslation: 40) == 40)
        // 40 · (1 + 0.7 · log10(2)) = 48.43
        #expect(abs(ConversationReplyMotion.bubbleOffset(forTranslation: 80) - 48.4288) < 0.001)
    }

    @Test func arrowGrowsBetween22And40Points() {
        #expect(ConversationReplyMotion.indicatorProgress(forOffset: 22) == 0)
        #expect(ConversationReplyMotion.indicatorProgress(forOffset: 31) == 0.5)
        #expect(ConversationReplyMotion.indicatorProgress(forOffset: 60) == 1)
        #expect(ConversationReplyMotion.indicatorScale(forProgress: 0) == 0.4)
        #expect(ConversationReplyMotion.indicatorScale(forProgress: 1) == 1)
    }

    @Test func onlyNearlyHorizontalSwipesStart() {
        #expect(ConversationReplyMotion.isSwipeAngle(velocity: CGPoint(x: 100, y: 30)))
        #expect(!ConversationReplyMotion.isSwipeAngle(velocity: CGPoint(x: 100, y: 35)))
        #expect(!ConversationReplyMotion.isSwipeAngle(velocity: .zero))
    }

    @Test func swipeAreaIsTheBubbleAtLeast156Wide() {
        let narrow = CGRect(x: 300, y: 0, width: 60, height: 40)
        #expect(ConversationReplyMotion.swipeArea(bubble: narrow, isOutgoing: true) == CGRect(x: 204, y: 0, width: 156, height: 40))
        #expect(ConversationReplyMotion.swipeArea(bubble: narrow, isOutgoing: false) == CGRect(x: 328, y: 0, width: 156, height: 40))
        let wide = CGRect(x: 16, y: 0, width: 200, height: 40)
        #expect(ConversationReplyMotion.swipeArea(bubble: wide, isOutgoing: false) == CGRect(x: 44, y: 0, width: 200, height: 40))
    }

    @Test func offsetCurveOvershootsThenLandsHome() {
        #expect(ConversationReplyMotion.offsetCurve(progress: 0) == 1)
        #expect(abs(ConversationReplyMotion.offsetCurve(progress: 0.3) - 1.1935) < 0.0001)
        #expect(abs(ConversationReplyMotion.offsetCurve(progress: 0.5) - 1.0625) < 0.0001)
        #expect(ConversationReplyMotion.offsetCurve(progress: 1) == 0)
    }

    @Test func easingRunsFasterAwayFromTheMiddleAndOnTheWayOut() {
        let mid = ConversationReplyMotion.easing(centerY: 437, itemHeight: 0, referenceY: 437, viewHeight: 874, animatingOut: false)
        let far = ConversationReplyMotion.easing(centerY: 874, itemHeight: 0, referenceY: 437, viewHeight: 874, animatingOut: false)
        let out = ConversationReplyMotion.easing(centerY: 437, itemHeight: 0, referenceY: 437, viewHeight: 874, animatingOut: true)
        #expect(abs(mid - 0.89) < 0.0001)
        #expect(far < mid && far > 0.825)
        #expect(abs(out - 0.84) < 0.0001)
        // One 60 Hz frame covers 1 - easing of the remaining distance.
        #expect(abs(ConversationReplyMotion.step(easing: 0.89, frameDuration: 1.0 / 60) - 0.11) < 0.0001)
    }
}

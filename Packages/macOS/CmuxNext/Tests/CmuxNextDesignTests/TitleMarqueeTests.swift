import AppKit
import QuartzCore
import Testing
@testable import CmuxNextDesign

/// Hover marquee and fade of clipped titles (user request on nxdog13:
/// "hover on workspace/tab that's too long needs a clean marquee with
/// subtle fade in both sides").
@Suite struct TitleFadeGeometryTests {
    private func geometry(text: CGFloat, span: CGFloat = 100, visible: CGFloat? = nil, lead: CGFloat = 6, trail: CGFloat = 0, fade: CGFloat = 24) -> TitleFadeGeometry {
        TitleFadeGeometry(textWidth: text, span: span, visibleWidth: visible ?? span, leadingPadding: lead, trailingPadding: trail, fadeWidth: fade)
    }

    @Test func aTitleThatFitsIsNotTruncatedAndHasNoMarquee() {
        let g = geometry(text: 80)
        #expect(!g.isTruncated)
        #expect(g.marqueeTravel == 0)
    }

    @Test func aClippedTitleFadesToClearAtItsVisibleEnd() {
        let g = geometry(text: 300, visible: 70, trail: 4)
        #expect(g.isTruncated)
        #expect(g.fadeEnd == 74, "the fade reaches into the trailing padding")
        #expect(g.fadeStart == 50)
    }

    @Test func theMarqueeEndsWithTheLastGlyphFullyOpaque() {
        let g = geometry(text: 300)
        // Clear at 100, opaque until 76: the end rests at 76.
        #expect(g.fadeStart == 76)
        #expect(g.marqueeTravel == 224)
    }

    @Test func theLeadingFadeLiesInThePaddingSoRestingTextIsNotDimmed() throws {
        let g = geometry(text: 300, lead: 8)
        #expect(g.maskFrame.x == -8)
        #expect(g.maskFrame.width == 108)
        let locations = g.maskLocations
        // clear at the padding's outer edge, opaque at the first glyph.
        #expect(locations[0] == 0)
        #expect(abs(locations[1] * 108 - 8) < 0.001)
    }

    @Test func theLayerWidensOnlyWhileTheMarqueeMayShowTheEnd() {
        let g = geometry(text: 300.4)
        #expect(g.layerWidth(marquee: false) == 100)
        #expect(g.layerWidth(marquee: true) == 301)
        #expect(geometry(text: 80).layerWidth(marquee: true) == 100)
    }
}

@Suite struct MarqueeTimingTests {
    @Test func runsOnlyWhenMovementAnimates() {
        #expect(MotionPolicy(speed: .fast, reduceMotion: false).marquee(travel: 100) != nil)
        #expect(MotionPolicy(speed: .fast, reduceMotion: true).marquee(travel: 100) == nil, "Reduce Motion: tooltip only")
        #expect(MotionPolicy(speed: .off, reduceMotion: false).marquee(travel: 100) == nil)
        #expect(MotionPolicy(speed: .fast, reduceMotion: false).marquee(travel: 1) == nil, "nothing worth revealing")
    }

    @Test func scrollsAtAReadingPaceAndNormalIsSlower() throws {
        let fast = try #require(MotionPolicy(speed: .fast, reduceMotion: false).marquee(travel: 200))
        #expect(fast.delay == MotionMarquee.delay)
        #expect(abs(fast.scroll - 200 / MotionMarquee.pointsPerSecond) < 0.0001)
        let short = try #require(MotionPolicy(speed: .fast, reduceMotion: false).marquee(travel: 4))
        #expect(short.scroll == MotionMarquee.minimumScroll)
        let normal = try #require(MotionPolicy(speed: .normal, reduceMotion: false).marquee(travel: 200))
        #expect(normal.scroll > fast.scroll && normal.delay > fast.delay)
    }

    @Test func theAnimationWaitsWithBeginTimeAndReturnsToRest() throws {
        let animation = try #require(Motion.marqueeAnimation(keyPath: "transform.translation.x", travel: 50, sign: -1, now: 100,
                                                             policy: MotionPolicy(speed: .fast, reduceMotion: false)) as? CAKeyframeAnimation)
        #expect(animation.beginTime == 100 + MotionMarquee.delay, "the hover delay is Core Animation's, not a timer")
        #expect((animation.values as? [NSNumber])?.map(\.doubleValue) == [0, -50, -50, 0])
        #expect(animation.repeatCount == 0, "one pass, then nothing runs")
    }
}

@MainActor @Suite struct TitleFadeMarqueeTests {
    private let moving = MotionPolicy(speed: .fast, reduceMotion: false)

    private func make(text: CGFloat, policy: MotionPolicy) -> (TitleFade, CALayer) {
        let layer = CALayer()
        let fade = TitleFade(textLayer: layer)
        fade.policy = { policy }
        fade.apply(TitleFadeGeometry(textWidth: text, span: 100, visibleWidth: 100, leadingPadding: 6, trailingPadding: 0, fadeWidth: 24),
                   frame: CGRect(x: 20, y: 0, width: 100, height: 16), animated: false)
        return (fade, layer)
    }

    @Test func startsOnAClippedTitleAndWidensItsLayer() {
        let (fade, layer) = make(text: 300, policy: moving)
        #expect(fade.activeMask != nil)
        #expect(fade.startMarquee())
        #expect(fade.isMarqueeActive)
        #expect(layer.animation(forKey: "marquee") != nil)
        #expect(fade.activeMask?.animation(forKey: "marquee") != nil, "the mask moves the other way and stays put")
        #expect(layer.bounds.width == 300)
        #expect(!fade.startMarquee(), "never stacks a second pass")
    }

    @Test func neverStartsOnATitleThatFits() {
        let (fade, layer) = make(text: 60, policy: moving)
        #expect(fade.activeMask == nil, "an unclipped title costs no mask layer")
        #expect(!fade.startMarquee())
        #expect(layer.animationKeys() == nil)
    }

    @Test func neverStartsUnderReduceMotionOrWithAnimationsOff() {
        #expect(!make(text: 300, policy: MotionPolicy(speed: .fast, reduceMotion: true)).0.startMarquee())
        #expect(!make(text: 300, policy: MotionPolicy(speed: .off, reduceMotion: false)).0.startMarquee())
    }

    @Test func pointerLeavingStopsAtOnceAndRestoresTheLayer() {
        let (fade, layer) = make(text: 300, policy: moving)
        fade.startMarquee()
        fade.stopMarquee()
        #expect(!fade.isMarqueeActive)
        #expect(layer.animation(forKey: "marquee") == nil)
        #expect(fade.activeMask?.animation(forKey: "marquee") == nil)
        // Not on screen, so nothing was presented mid-scroll: back at rest now.
        #expect(layer.bounds.width == 100)
    }

    @Test func aTitleThatStopsBeingClippedStopsItsMarquee() {
        let (fade, layer) = make(text: 300, policy: moving)
        fade.startMarquee()
        fade.apply(TitleFadeGeometry(textWidth: 300, span: 400, visibleWidth: 400, leadingPadding: 6, trailingPadding: 0, fadeWidth: 24),
                   frame: CGRect(x: 20, y: 0, width: 400, height: 16), animated: false)
        #expect(!fade.isMarqueeActive)
        #expect(layer.mask == nil)
    }
}

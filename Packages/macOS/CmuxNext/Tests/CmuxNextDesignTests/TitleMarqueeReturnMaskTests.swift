import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Lawrence 2026-11-16 (video, "notice what's wrong about fade on mouseup"): the pointer left a sidebar row whose
/// title the hover marquee had scrolled ("…ation race condition"). The title sprang back, but the row's hover
/// controls clear at once, so the layout right after found the title no longer clipped and dropped its fade mask
/// while the text still slid home: for ~150 ms the head of the title ("Fix tab cr…") drew unclipped across the
/// row's left padding, with no fade at either end. The mask now stays (fixed on screen, its leading fade easing
/// back to rest) until the title is home; the end shows at once with the cleared controls.
@MainActor @Suite struct TitleMarqueeReturnMaskTests {
    static let span: CGFloat = 200
    /// Width of the hover controls over the title's end.
    static let occlusion: CGFloat = 60

    static func geometry(occlusion: CGFloat) -> TitleFadeGeometry {
        // 170 pt of text: clipped before the controls (140 pt clear), whole without them.
        TitleFadeGeometry(textWidth: 170, span: span, visibleWidth: span - occlusion, leadingPadding: 0,
                          trailingPadding: 0, fadeWidth: 24)
    }

    /// A hovered title whose marquee has scrolled `shown` points left.
    static func scrolledTitle(shown: CGFloat) -> (TitleFade, CALayer) {
        let text = CALayer()
        let fade = TitleFade(textLayer: text, gate: Motion.sidebar)
        fade.policy = { MotionPolicy(speed: .fast, reduceMotion: false) }
        fade.shownTranslation = { shown }
        let frame = CGRect(x: 0, y: 0, width: span, height: 16)
        fade.apply(geometry(occlusion: occlusion), frame: frame, animated: false)
        #expect(fade.startMarquee(), "a clipped title runs no marquee, so this test proves nothing")
        return (fade, text)
    }

    /// The sidebar row on hover-out: `stopMarquee()`, then a layout with the controls gone and no fade.
    @Test func titleSlidingHomeKeepsItsMaskAfterTheControlsClear() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (fade, text) = Self.scrolledTitle(shown: -40)
        let mask = try #require(text.mask)
        fade.stopMarquee()
        try #require(text.animation(forKey: TitleFade.keyPath) != nil, "the title did not spring back, so this test proves nothing")
        fade.apply(Self.geometry(occlusion: 0), frame: CGRect(x: 0, y: 0, width: Self.span, height: 16), animated: false)
        #expect(text.mask === mask, "the fade mask went while the title still slides home: its head draws over the row's padding")
        #expect(mask.animation(forKey: TitleFade.keyPath) != nil, "the mask does not hold still while the title slides under it")
        // The end is no longer covered: it reads whole at once (the stops end open).
        let stops = try #require((mask as? CAGradientLayer)?.locations).map(\.doubleValue)
        #expect(Array(stops.suffix(3)) == [1, 1, 1], "the title's end still fades after the controls cleared: \(stops)")
    }

    /// A title already at rest drops its mask at once when it stops clipping (no idle mask layer).
    @Test func titleAtRestDropsItsMaskWhenItStopsClipping() {
        let (fade, text) = Self.scrolledTitle(shown: 0)
        fade.stopMarquee()
        fade.apply(Self.geometry(occlusion: 0), frame: CGRect(x: 0, y: 0, width: Self.span, height: 16), animated: false)
        #expect(text.mask == nil, "an unclipped title at rest keeps a mask")
    }

    /// The tab's order (layout first, while the marquee is still active): the scrolled title springs back instead
    /// of jumping home, under its mask.
    @Test func layoutThatEndsTheClipSpringsAScrolledTitleBack() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (fade, text) = Self.scrolledTitle(shown: -40)
        fade.apply(Self.geometry(occlusion: 0), frame: CGRect(x: 0, y: 0, width: Self.span, height: 16), animated: true)
        #expect(!fade.isMarqueeActive)
        #expect(text.animation(forKey: TitleFade.keyPath) != nil, "the scrolled title jumped home")
        #expect(text.mask != nil, "the mask went while the title slides home")
    }
}

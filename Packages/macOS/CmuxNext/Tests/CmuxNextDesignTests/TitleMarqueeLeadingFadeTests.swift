import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Lawrence 2026-11-09 ("left side transparency is bad", a hovered sidebar row "Fix popover transparency in
/// side…" scrolled to "popover…"): a text-only sidebar row has no padding left of its first glyph
/// (`leadingPadding` 0), so the hover marquee cut the leaving glyphs with a hard edge at the text column and a sliced
/// stub of the "x" stayed at the row's left edge. While a marquee scrolls, the leaving glyphs fade out over a whole
/// fade length (`fadeWidth`), reaching into the text column where the padding is shorter; at rest the first glyph
/// stays fully opaque.
@MainActor @Suite struct TitleMarqueeLeadingFadeTests {
    static let fadeWidth: CGFloat = 24
    static let span: CGFloat = 120

    /// A clipped title laid out in a fresh layer with `padding` left of its first glyph, marquee started.
    static func scrolledTitle(padding: CGFloat) throws -> (TitleFade, CAGradientLayer) {
        let text = CALayer()
        let fade = TitleFade(textLayer: text, gate: Motion.sidebar)
        fade.policy = { MotionPolicy(speed: .fast, reduceMotion: false) }
        let geometry = TitleFadeGeometry(textWidth: 400, span: span, visibleWidth: span, leadingPadding: padding,
                                         trailingPadding: 0, fadeWidth: fadeWidth)
        fade.apply(geometry, frame: CGRect(x: padding, y: 0, width: span, height: 16), animated: false)
        #expect(fade.startMarquee(), "a clipped title runs no marquee, so this test proves nothing")
        return (fade, try #require(text.mask as? CAGradientLayer, "a clipped title has no fade mask"))
    }

    /// Points from the mask's clear start to where it is opaque (its first two stops), in a `width`-point mask.
    static func leadingRamp(_ stops: [NSNumber], width: CGFloat) -> CGFloat {
        CGFloat(stops[1].doubleValue - stops[0].doubleValue) * width
    }

    @Test(arguments: [CGFloat(0), 4, 30])
    func leavingGlyphsFadeOverAWholeFadeLength(padding: CGFloat) throws {
        let (fade, mask) = try Self.scrolledTitle(padding: padding)
        defer { fade.stopMarquee(animated: false) }
        let width = padding + Self.span
        // At rest the first glyph is fully opaque: the ramp ends where it starts.
        let rest = try #require(mask.locations)
        #expect(abs(Self.leadingRamp(rest, width: width) - padding) <= 0.5,
                "at rest the title fades over \(Self.leadingRamp(rest, width: width)) pt, its padding is \(padding)")
        // Scrolled, the glyphs that leave fade out over at least a fade length.
        let scroll = mask.animationKeys()?.lazy.compactMap { mask.animation(forKey: $0) as? CAKeyframeAnimation }
            .first { $0.keyPath == "locations" }
        // Padding of a fade length or more already fades the leaving glyphs at rest: nothing to animate.
        guard padding < Self.fadeWidth || scroll != nil else { return }
        let values = try #require(scroll?.values as? [[NSNumber]], "the marquee does not fade the leaving glyphs")
        let scrolled = values.map { Self.leadingRamp($0, width: width) }.max() ?? 0
        #expect(scrolled >= max(padding, Self.fadeWidth) - 0.5,
                "padding \(padding): the leaving glyphs fade over \(scrolled) pt, a fade length is \(Self.fadeWidth)")
        // It begins and ends at rest, with the scroll.
        #expect(values.first == rest && values.last == rest, "the leading fade does not start and end at rest")
    }
}

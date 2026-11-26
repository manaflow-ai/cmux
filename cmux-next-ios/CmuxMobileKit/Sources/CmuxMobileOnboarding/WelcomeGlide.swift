#if os(iOS)
import CmuxMobileDesign
import CoreText
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// Geist, the website's typeface (SIL Open Font License 1.1,
/// `Resources/Fonts/Geist-OFL.txt`), bundled with this module and registered
/// for this process on first use.
enum Geist: String, Sendable {
    case regular = "Geist-Regular"
    case semibold = "Geist-SemiBold"

    private static let registered: Bool = {
        for face in ["Geist-Regular", "Geist-SemiBold"] {
            // Processed resources land at the bundle's top level; look in Fonts/ too.
            let url = Bundle.module.url(forResource: face, withExtension: "ttf")
                ?? Bundle.module.url(forResource: face, withExtension: "ttf", subdirectory: "Fonts")
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
        return true
    }()

    /// Text that grows with Dynamic Type like `style`.
    func font(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        _ = Self.registered
        return .custom(rawValue, size: size, relativeTo: style)
    }

    /// Geist at `size`, or the system font when Geist is not registered
    /// (a missing resource): CoreText would otherwise substitute some other
    /// face for the unknown name.
    func ctFont(size: CGFloat) -> CTFont {
        _ = Self.registered
        let font = CTFontCreateWithName(rawValue as CFString, size, nil)
        guard CTFontCopyPostScriptName(font) as String == rawValue else {
            return UIFont.systemFont(ofSize: size, weight: self == .semibold ? .semibold : .regular) as CTFont
        }
        return font
    }
}

/// The welcome's top section ("Glide"): the cmux wordmark and the tagline.
///
/// A block cursor in the chevron's gradient blinks in the middle of the
/// screen, types "cmux" in Geist SemiBold with the typed line kept centered,
/// blinks once more, then bends into the chevron and flies to the left of the
/// word while the word slides right on the same curve, so the lockup lands
/// centered. One shape, never a swap. The cursor keeps one rhythm
/// (`CursorRhythm`) from the first blink to the move.
struct WelcomeGlide: View {
    var t: Double

    /// How long the entrance runs (the welcome's timeline stays awake that long).
    static var entranceDuration: Double { CursorRhythm.welcome.moveAt + flight + 0.25 }
    /// The cursor's flight home.
    private static var flight: Double { 0.5 }
    private static let word = GlyphOutline.make("cmux", font: Geist.semibold.ctFont(size: 100), tracking: -2.5)

    var body: some View {
        let word = Self.word
        let rhythm = CursorRhythm.welcome
        let flight = Self.flight
        let xh = word.xHeight
        let chevronHeight = xh * 1.42
        let chevronWidth = chevronHeight * Chevron.aspect
        // The word's place in the settled lockup (the chevron is at x 0).
        let lockupWordX = chevronWidth + xh * 0.42
        // Centered on ink: the canvas ends at the x's last stroke, so the
        // settled lockup (chevron to x) sits exactly in the middle.
        let ink = word.path.boundingRect
        let width = lockupWordX + ink.maxX
        let height = chevronHeight
        let taglineAt = rhythm.moveAt + 0.45
        // As the cursor lands, the icon's own chevron (its pixels, glow
        // included) comes in over the drawn one, which matches it exactly.
        let landAt = rhythm.moveAt + flight
        let landed = IntroEase.out(IntroEase.seg(t, landAt - 0.04, landAt + 0.22))
        VStack(spacing: 22) {
            Canvas { context, size in
                typealias E = IntroEase
                let scale = size.width / width
                context.scaleBy(x: scale, y: scale)
                let baseline = (height + xh) / 2
                let label = GraphicsContext.Shading.color(theme.colors.label.color)
                let blockWidth = xh * 0.6, blockHeight = xh * 1.2

                // Typing: one letter per 0.1 s; the cursor steps after each,
                // measured from the word's left edge.
                let typedAt = word.glyphs.indices.map { rhythm.typeStart + 0.1 * Double($0) }
                let step = xh * 0.1
                var cursorOffset: CGFloat = 0
                for (glyph, at) in zip(word.glyphs, typedAt) {
                    let p = CGFloat(E.outQuint(E.seg(t, at, at + 0.08)))
                    cursorOffset += (glyph.x + glyph.advance + step - cursorOffset) * p
                }
                let m = E.inOut(E.seg(t, rhythm.moveAt, rhythm.moveAt + flight))

                // The typed line's ink (first letter, or the cursor alone before
                // it, to the cursor's right edge) is centered in the canvas, then
                // slides into the lockup with the cursor.
                let lineLeft = min(ink.minX, cursorOffset)
                let typingWordX = (width - lineLeft - cursorOffset - blockWidth) / 2
                let wordX = typingWordX + (lockupWordX - typingWordX) * CGFloat(m)

                // The cursor, drawn first: on its way home it passes behind the
                // letters, which stay crisp over it.
                if t >= rhythm.onAt, !rhythm.isOff(t), landed < 1 {
                    // A block a little taller than the x-height, where typing left it.
                    let block = CGRect(x: typingWordX + cursorOffset, y: baseline + xh * 0.1 - blockHeight,
                                       width: blockWidth, height: blockHeight)
                    // Eight points each, in the same order, so the block bends into
                    // the arrow: its right side becomes the tip, its left side the notch.
                    let from: [CGPoint] = [
                        CGPoint(x: block.minX, y: block.minY), CGPoint(x: block.maxX, y: block.minY),
                        CGPoint(x: block.maxX, y: block.midY), CGPoint(x: block.maxX, y: block.maxY),
                        CGPoint(x: block.minX, y: block.maxY), CGPoint(x: block.minX, y: block.minY + (1 - Chevron.bottomArm) * blockHeight),
                        CGPoint(x: block.minX, y: block.midY), CGPoint(x: block.minX, y: block.minY + Chevron.topArm * blockHeight),
                    ]
                    // The chevron's six corners plus its outer edges' midpoints,
                    // in the block's order (its right side becomes the tip, its
                    // left side the notch).
                    let c = Chevron.corners(at: .zero, height: chevronHeight)
                    let to = [c[0], CGPoint(x: (c[0].x + c[1].x) / 2, y: (c[0].y + c[1].y) / 2), c[1],
                              CGPoint(x: (c[1].x + c[2].x) / 2, y: (c[1].y + c[2].y) / 2), c[2], c[3], c[4], c[5]]
                    // A shallow arc on the way.
                    let lift = -CGFloat(sin(Double.pi * m)) * xh * 0.35
                    var shape = Path()
                    shape.addLines(zip(from, to).map { a, b in
                        CGPoint(x: a.x + (b.x - a.x) * CGFloat(m), y: a.y + (b.y - a.y) * CGFloat(m) + lift)
                    })
                    shape.closeSubpath()
                    let box = shape.boundingRect
                    context.fill(shape, with: Chevron.shading(from: box.minX, to: box.maxX))
                }

                for (glyph, at) in zip(word.glyphs, typedAt) {
                    let shown = E.out(E.seg(t, at, at + 0.1))
                    guard shown > 0 else { continue }
                    var letter = context
                    letter.opacity = shown
                    letter.fill(glyph.path.applying(CGAffineTransform(translationX: wordX, y: baseline)), with: label)
                }
            }
            .aspectRatio(width / height, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                // In the tree from the first frame, transparent until the landing:
                // the icon's asset lookup, decode and upload happen while the word
                // types, not in the frame its crossfade starts (made there, a
                // first run held that frame for 168 ms and skipped the crossfade).
                GeometryReader { proxy in
                    // The canvas's points per unit. The chevron lands at its
                    // top left, `chevronHeight` tall; CmuxLogoMark (the launch
                    // screen's view) draws the icon layer with its solid
                    // chevron that tall, centered, glow around it.
                    let unit = proxy.size.width / width
                    CmuxLogoMark(chevronHeight: chevronHeight * unit)
                        .position(x: chevronWidth / 2 * unit, y: chevronHeight / 2 * unit)
                        .opacity(landed)
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: 292)
            .padding(.horizontal, 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "cmux"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("welcome.wordmark")

            Text("Your Macs, in your pocket")
                .font(Geist.regular.font(size: 17, relativeTo: .body))
                // `legal`, not `label2`: label2 is 3.4:1 on white (fails WCAG AA
                // for 17 pt text); legal is 5.6:1 in light, label2's 6.2:1 in dark.
                .foregroundStyle(theme.colors.legal)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, theme.metrics.sideMargin)
                .opacity(IntroEase.out(IntroEase.seg(t, taglineAt, taglineAt + 0.3)))
        }
    }
}

/// When Glide's cursor shows. It appears at 0.04 s, is on for 60% of `cycle`
/// and off for 40% (the opening blink), holds on for a beat (11/30 of the
/// cycle) before the first letter, and types 0.1 s a letter. After the x it
/// keeps the rhythm: on for 60% of the cycle, off for 40%, and on for 60%
/// again before it starts to bend into the chevron, so the last gap before
/// the move is the gap between blinks.
private struct CursorRhythm: Sendable {
    /// The welcome's: a 450 ms blink. Off 0.31 to 0.49 s, typing from 0.66 s,
    /// off again 1.23 to 1.41 s, moving at 1.68 s.
    static let welcome = CursorRhythm(cycle: 0.45)

    var cycle: Double

    var onAt: Double { 0.04 }
    var offAt: Double { onAt + 0.6 * cycle }
    var backAt: Double { offAt + 0.4 * cycle }
    var typeStart: Double { backAt + cycle * 11 / 30 }
    /// When the x is typed (the fourth letter).
    var lastTyped: Double { typeStart + 0.3 }
    var finalOffAt: Double { lastTyped + 0.6 * cycle }
    var finalBackAt: Double { finalOffAt + 0.4 * cycle }
    /// When the cursor starts to bend into the chevron and fly home.
    var moveAt: Double { finalBackAt + 0.6 * cycle }

    func isOff(_ t: Double) -> Bool {
        (t >= offAt && t < backAt) || (t >= finalOffAt && t < finalBackAt)
    }
}

/// The cmux chevron, measured from the app icon's only layer (`AppIcon.icon`,
/// `cmux-icon-chevron 2.png`, 639 x 818 px, its solid chevron 457 x 636 px):
/// geometry in units of the chevron's height, sharp corners, and a colour
/// ramp that runs strictly left to right. The launch screen's `LaunchMark` is
/// that layer's pixels (`scripts/generate-launch-mark.swift`); the welcome
/// lands on the same image, so the two never differ.
private enum Chevron {
    /// Width over height.
    static let aspect: CGFloat = 0.7186
    /// The tip's height (the middle, to a pixel).
    static let tipY: CGFloat = 0.4992
    /// The inner vertex (the notch), from the left.
    static let notchX: CGFloat = 0.3884
    /// The arms' height where they are cut flat at the left: top and bottom.
    static let topArm: CGFloat = 0.2201
    static let bottomArm: CGFloat = 0.2217

    /// Its corners, clockwise from the top left, `height` tall at `origin`.
    static func corners(at origin: CGPoint, height h: CGFloat) -> [CGPoint] {
        let units: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: aspect, y: tipY), CGPoint(x: 0, y: 1),
            CGPoint(x: 0, y: 1 - bottomArm), CGPoint(x: notchX, y: tipY), CGPoint(x: 0, y: topArm),
        ]
        return units.map { CGPoint(x: origin.x + $0.x * h, y: origin.y + $0.y * h) }
    }

    /// The colour ramp, sampled at 17 even steps across the solid chevron
    /// (each the mean of its column's opaque pixels): 0xRRGGBB, evenly spaced
    /// from the left edge (0) to the tip (1).
    private static let rampColors: [UInt32] = [
        0x07CCFE, 0x05CEFF, 0x0AC8FE, 0x10C1FD, 0x16B9FC, 0x1CB2FB, 0x22AAFA, 0x28A2F9,
        0x2E9BF8, 0x3494F7, 0x3A8CF6, 0x4184F5, 0x467DF5, 0x4C77F4, 0x5071F4, 0x536EF3,
        0x536DF3,
    ]

    static let ramp: [Gradient.Stop] = rampColors.enumerated().map { index, hex in
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        let location = CGFloat(index) / CGFloat(rampColors.count - 1)
        return Gradient.Stop(color: Color(red: red, green: green, blue: blue), location: location)
    }

    /// The ramp from `minX` (cyan) to `maxX` (indigo), for a Canvas.
    static func shading(from minX: CGFloat, to maxX: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: ramp), startPoint: CGPoint(x: minX, y: 0), endPoint: CGPoint(x: maxX, y: 0))
    }
}

/// Text as outlines (CoreText), so the wordmark draws and animates as paths.
/// Baseline at y = 0, y down.
private struct GlyphOutline: Sendable {
    struct Glyph: Sendable {
        var path: Path
        var x: CGFloat
        var advance: CGFloat
    }

    var path: Path
    var glyphs: [Glyph]
    var xHeight: CGFloat

    static func make(_ text: String, font: CTFont, tracking: CGFloat = 0) -> GlyphOutline {
        let characters = Array(text.utf16)
        var ids = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, characters, &ids, characters.count)
        var advances = [CGSize](repeating: .zero, count: ids.count)
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, ids, &advances, ids.count)
        var path = Path()
        var glyphs: [Glyph] = []
        var x: CGFloat = 0
        for (id, advance) in zip(ids, advances) {
            var glyph = Path()
            if let outline = CTFontCreatePathForGlyph(font, id, nil) {
                glyph.addPath(Path(outline), transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: 0))
            }
            path.addPath(glyph)
            glyphs.append(Glyph(path: glyph, x: x, advance: advance.width))
            x += advance.width + tracking
        }
        return GlyphOutline(path: path, glyphs: glyphs, xHeight: CTFontGetXHeight(font))
    }
}
#endif

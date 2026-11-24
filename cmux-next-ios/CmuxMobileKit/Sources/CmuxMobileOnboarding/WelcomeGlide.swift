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
                if t >= rhythm.onAt, !rhythm.isOff(t) {
                    // A block a little taller than the x-height, where typing left it.
                    let block = CGRect(x: typingWordX + cursorOffset, y: baseline + xh * 0.1 - blockHeight,
                                       width: blockWidth, height: blockHeight)
                    // Eight points each, in the same order, so the block bends into
                    // the arrow: its right side becomes the tip, its left side the notch.
                    let from: [CGPoint] = [
                        CGPoint(x: block.minX, y: block.minY), CGPoint(x: block.maxX, y: block.minY),
                        CGPoint(x: block.maxX, y: block.midY), CGPoint(x: block.maxX, y: block.maxY),
                        CGPoint(x: block.minX, y: block.maxY), CGPoint(x: block.minX, y: block.minY + 0.76 * blockHeight),
                        CGPoint(x: block.minX, y: block.midY), CGPoint(x: block.minX, y: block.minY + 0.24 * blockHeight),
                    ]
                    let h = chevronHeight
                    let corners: [(CGFloat, CGFloat)] = [(0, 0), (0.36, 0.25), (0.72, 0.5), (0.36, 0.75), (0, 1), (0, 0.76), (0.38, 0.5), (0, 0.24)]
                    let to = corners.map { CGPoint(x: $0.0 * h, y: $0.1 * h) }
                    // A shallow arc on the way.
                    let lift = -CGFloat(sin(Double.pi * m)) * xh * 0.35
                    var shape = Path()
                    shape.addLines(zip(from, to).map { a, b in
                        CGPoint(x: a.x + (b.x - a.x) * CGFloat(m), y: a.y + (b.y - a.y) * CGFloat(m) + lift)
                    })
                    shape.closeSubpath()
                    let box = shape.boundingRect
                    context.fill(shape, with: ChevronGradient.shading(from: CGPoint(x: box.minX, y: 0), to: CGPoint(x: box.maxX, y: 0)))
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
            .frame(maxWidth: 292)
            .padding(.horizontal, 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "cmux"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("welcome.wordmark")

            Text("Your Macs, in your pocket")
                .font(Geist.regular.font(size: 17, relativeTo: .body))
                .foregroundStyle(theme.colors.label2)
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

/// The app icon's chevron colours (`AppIcon.icon`): cyan to indigo, left to right.
private enum ChevronGradient {
    static let start = (red: 0.0, green: 0.78, blue: 1.0)
    static let end = (red: 0.36, green: 0.36, blue: 1.0)

    static func color(at x: Double) -> Color {
        let x = min(max(x, 0), 1)
        return Color(red: start.red + (end.red - start.red) * x,
                     green: start.green + (end.green - start.green) * x,
                     blue: start.blue + (end.blue - start.blue) * x)
    }

    /// The gradient from `a` (cyan) to `b` (indigo), for a Canvas.
    static func shading(from a: CGPoint, to b: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [color(at: 0), color(at: 1)]), startPoint: a, endPoint: b)
    }
}

/// The app icon's chevron proportions: 0.72 as wide as it is tall.
private enum Chevron {
    static let aspect: CGFloat = 0.72
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

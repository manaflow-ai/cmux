#if os(iOS)
import CmuxMobileDesign
import CoreText
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard
private typealias E = IntroEase

/// Prototype, round 4: directions for the welcome's top section. Each leads
/// with the app icon's chevron in its gradient (the only colour on the page)
/// and sets "cmux" in Geist, the website's typeface, or draws it; each has
/// its own reveal that plays once. One line under the mark, nothing at the
/// top. The sign-in rows (Liquid Glass) and the legal line are the same in
/// every variant. `now` is the shipped design: Release shows it until a
/// direction is picked; then the picked one replaces it and the rest of this
/// file, the picker and the enum go (prototype skill, phase 6).
enum WelcomeHeroVariant: Int, CaseIterable, Identifiable, Sendable {
    /// Today: lockup at the top, Mac and phone line art, one line.
    case now
    /// The chevron and "cmux" in Geist SemiBold, as on the website; the
    /// launch chevron glides into place.
    case lockup
    /// The website's hero on a phone: the app icon tile, "cmux", and the line
    /// typed out with a blinking caret, left-aligned.
    case site
    /// The chevron traces its outline, fills and blooms; the letters rise out of a blur.
    case bloom
    /// A block cursor types "cmux", then bends into the chevron as it flies home.
    case morph
    /// Geist Mono letters scramble through terminal glyphs and lock in, left to right.
    case decode
    /// The lockup comes in from a blur; one gradient sheen sweeps across it.
    case shimmer
    /// Geist Black cut into scan lines that thicken toward the baseline.
    case raster
    /// A geometric monoline drawn over its own construction, stroke by stroke.
    case draft
    /// Five keycaps: c, m, u, x are typed, then the chevron key lights.
    case keys
    /// Circuit traces with 45° corners and pads; the current runs letter by letter.
    case circuit
    /// One hollow tube, lit like a sign: the letters flicker on in turn.
    case tube
    /// Morph, centered: "cmux" types out centered on the screen, then as the
    /// cursor bends into the chevron and flies to its left, the word slides
    /// right, so the lockup lands centered.
    case glide
    /// Glide with a slower opening blink: 450, 600 and 900 ms per blink
    /// (Glide's is 300 ms), for comparing speeds; the rest of the reveal is
    /// the same, later by the extra time.
    case glide450, glide600, glide900

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .now: "Now"
        case .lockup: "Lockup"
        case .site: "Site"
        case .bloom: "Bloom"
        case .morph: "Morph"
        case .decode: "Decode"
        case .shimmer: "Shimmer"
        case .raster: "Raster"
        case .draft: "Draft"
        case .keys: "Keys"
        case .circuit: "Circuit"
        case .tube: "Tube"
        case .glide: "Glide"
        case .glide450: "Glide450"
        case .glide600: "Glide600"
        case .glide900: "Glide900"
        }
    }

    /// What the picker shows.
    var label: String {
        switch self {
        case .glide450: "Glide 450"
        case .glide600: "Glide 600"
        case .glide900: "Glide 900"
        default: name
        }
    }

    /// One opening cursor blink in Morph and Glide (on, then off), in seconds.
    var blinkCycle: Double {
        switch self {
        case .glide450: 0.45
        case .glide600: 0.6
        case .glide900: 0.9
        default: 0.3
        }
    }

    /// The picker's rows: round 4's Geist directions (Glide beside the Morph
    /// it varies), Shimmer and round 3's drawn marks, then Glide's slower
    /// opening blinks.
    static let pickerRows: [[WelcomeHeroVariant]] = [
        [.lockup, .site, .bloom, .morph, .glide, .decode],
        [.shimmer, .raster, .draft, .keys, .circuit, .tube],
        [.glide450, .glide600, .glide900],
    ]

    /// The variants the picker offers (today's design is in the report, not the pill).
    static let directions: [WelcomeHeroVariant] = pickerRows.flatMap { $0 }

    /// The launch screen's chevron glides into this variant's own chevron;
    /// otherwise it dissolves in place while the wordmark comes in.
    var carriesMark: Bool { self == .now || self == .lockup }

    /// How long the variant's entrance runs (the welcome's timeline stays awake that long).
    var entranceDuration: Double {
        switch self {
        case .now: WelcomeArt.introDuration + 0.1
        case .lockup: 0.9
        case .raster, .decode: 1.0
        case .circuit: 1.2
        case .draft, .keys, .tube, .bloom: 1.3
        case .shimmer: 1.4
        case .morph: 1.5
        case .site: 1.6
        case .glide, .glide450, .glide600, .glide900: 1.75 + OpeningBlink(cycle: blinkCycle).delay
        }
    }

    /// The variant this process shows: `-cmux-mobile-welcome-hero <name>`
    /// (DEBUG; pins it and hides the picker), else the picker's last choice,
    /// else the first direction. Release always shows `now`.
    static var launchChoice: (variant: WelcomeHeroVariant, pinned: Bool) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-cmux-mobile-welcome-hero"), i + 1 < arguments.count {
            let value = arguments[i + 1].lowercased()
            if let v = allCases.first(where: { $0.name.lowercased() == value }) { return (v, true) }
        }
        let stored = UserDefaults.standard.object(forKey: storeKey) as? Int
        return (stored.flatMap(WelcomeHeroVariant.init(rawValue:)) ?? directions[0], false)
        #else
        return (.now, true)
        #endif
    }

    static let storeKey = "cmuxMobile.prototype.welcomeHero.v4"
}

/// Geist, the website's typeface (SIL Open Font License 1.1,
/// `Resources/Fonts/Geist-OFL.txt`), bundled with this module and registered
/// for this process on first use.
enum Geist: String, Sendable {
    case regular = "Geist-Regular"
    case semibold = "Geist-SemiBold"
    case black = "Geist-Black"
    case monoMedium = "GeistMono-Medium"

    private static let registered: Bool = {
        for face in ["Geist-Regular", "Geist-SemiBold", "Geist-Black", "GeistMono-Medium"] {
            // Processed resources land at the bundle's top level; look in Fonts/ too.
            let url = Bundle.module.url(forResource: face, withExtension: "ttf")
                ?? Bundle.module.url(forResource: face, withExtension: "ttf", subdirectory: "Fonts")
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
        return true
    }()

    /// At a fixed size: a logo does not grow with Dynamic Type.
    func font(size: CGFloat) -> Font {
        _ = Self.registered
        return .custom(rawValue, fixedSize: size)
    }

    /// Text that grows with Dynamic Type like `style`.
    func font(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        _ = Self.registered
        return .custom(rawValue, size: size, relativeTo: style)
    }

    func ctFont(size: CGFloat) -> CTFont {
        _ = Self.registered
        return CTFontCreateWithName(rawValue as CFString, size, nil)
    }
}

/// The tagline every direction shares, so the comparison is about the mark.
struct WelcomeHeroTagline: View {
    var body: some View {
        Text("Your Macs, in your pocket")
            .font(Geist.regular.font(size: 17, relativeTo: .body))
            .foregroundStyle(theme.colors.label2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, theme.metrics.sideMargin)
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

    /// Left to right across the view it fills.
    static var style: LinearGradient {
        LinearGradient(colors: [color(at: 0), color(at: 1)], startPoint: .leading, endPoint: .trailing)
    }
}

/// The app icon's chevron, filled: `height` tall, 0.72 × `height` wide.
private enum Chevron {
    static let aspect: CGFloat = 0.72
    /// Its corners in units of its height: outer top, tip, outer bottom, then the notch.
    static let corners: [(CGFloat, CGFloat)] = [(0, 0), (0.72, 0.5), (0, 1), (0, 0.76), (0.38, 0.5), (0, 0.24)]

    static func path(x: CGFloat, y: CGFloat, height h: CGFloat) -> Path {
        var path = Path()
        path.addLines(corners.map { CGPoint(x: x + $0.0 * h, y: y + $0.1 * h) })
        path.closeSubpath()
        return path
    }
}

/// The chevron as a shape, as tall as its frame.
private struct ChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        Chevron.path(x: rect.minX, y: rect.minY, height: rect.height)
    }
}

/// An sRGB colour from `0xRRGGBB`.
private func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255, opacity: alpha)
}

private extension Path {
    /// An arc sampled as short lines, angles in degrees with y down (90 is
    /// straight down), so its direction never hangs on what `clockwise`
    /// means in flipped coordinates.
    mutating func addSampledArc(center: CGPoint, radius: CGFloat, from a: Double, to b: Double) {
        let steps = max(8, Int(abs(b - a) / 3))
        for i in 0...steps {
            let angle = (a + (b - a) * Double(i) / Double(steps)) * .pi / 180
            let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
            if let current = currentPoint {
                if i > 0 || hypot(current.x - point.x, current.y - point.y) > 0.0001 { addLine(to: point) }
            } else {
                move(to: point)
            }
        }
    }
}

/// Text as outlines (CoreText), so a mark built from it clips and animates
/// as paths. Baseline at y = 0, y down.
private struct GlyphOutline: Sendable {
    struct Glyph: Sendable {
        var path: Path
        var x: CGFloat
        var advance: CGFloat
    }

    var path: Path
    var glyphs: [Glyph]
    var xHeight: CGFloat
    /// The advance of the whole run.
    var width: CGFloat

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
        return GlyphOutline(path: path, glyphs: glyphs, xHeight: CTFontGetXHeight(font), width: x - tracking)
    }
}

/// A geometric monoline "cmux" (lowercase, x-height only) on its centerline,
/// in units of the x-height: y 0 is the x-height line, 1 the baseline. `w` is
/// the stroke width. Butt-capped stems run to the guide lines (the x is cut
/// flat there); round caps stop half a stroke short so the caps land on them.
private struct Monoline: Sendable {
    struct Glyph: Sendable {
        var path: Path
        var width: CGFloat
        /// Its construction (Draft): the circles behind bowls and arches, the x's diagonal.
        var guides: Path
        /// Its diagonals run past the guide lines: draw it clipped to the band.
        var clipsToBand = false
    }

    var glyphs: [Glyph]

    init(stroke w: CGFloat, roundCaps: Bool) {
        let h = w / 2
        let inset = roundCaps ? h : 0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

        // c: a circle open on the right, its ends 50° off the horizontal.
        let r = 0.5 - h
        var c = Path()
        c.addSampledArc(center: p(0.5, 0.5), radius: r, from: -50, to: -310)
        let cWidth = 0.5 + r * CGFloat(cos(50 * Double.pi / 180)) + h

        // m: two half-circle arches on three stems.
        let mWidth: CGFloat = 1.22
        let x0 = h, x2 = mWidth - h, ra = (x2 - x0) / 4, x1 = x0 + 2 * ra, archY = h + ra
        var m = Path()
        m.move(to: p(x0, 1 - inset))
        m.addLine(to: p(x0, archY))
        m.addSampledArc(center: p(x0 + ra, archY), radius: ra, from: 180, to: 360)
        m.addLine(to: p(x1, 1 - inset))
        m.move(to: p(x1, archY))
        m.addSampledArc(center: p(x1 + ra, archY), radius: ra, from: 180, to: 360)
        m.addLine(to: p(x2, 1 - inset))
        var mGuides = circle(p(x0 + ra, archY), ra)
        mGuides.addPath(circle(p(x1 + ra, archY), ra))

        // u: a half-circle bowl; the right stem runs on to the baseline.
        let uWidth: CGFloat = 0.74
        let u0 = h, u1 = uWidth - h, ru = (u1 - u0) / 2, bowlY = 1 - h - ru
        var u = Path()
        u.move(to: p(u0, inset))
        u.addLine(to: p(u0, bowlY))
        u.addSampledArc(center: p(u0 + ru, bowlY), radius: ru, from: 180, to: 0)
        u.addLine(to: p(u1, inset))
        u.move(to: p(u1, bowlY))
        u.addLine(to: p(u1, 1 - inset))

        // x: two diagonals.
        let xWidth: CGFloat = 0.78
        var x = Path()
        var xGuides = Path()
        if roundCaps {
            x.move(to: p(h, h)); x.addLine(to: p(xWidth - h, 1 - h))
            x.move(to: p(xWidth - h, h)); x.addLine(to: p(h, 1 - h))
        } else {
            // The centerline meets the guides `a` in from the sides, and runs
            // `over` past them, to be cut flat by the band.
            let a = h * 1.15, run = xWidth - 2 * a, over: CGFloat = 0.2
            x.move(to: p(a - run * over, -over)); x.addLine(to: p(xWidth - a + run * over, 1 + over))
            x.move(to: p(xWidth - a + run * over, -over)); x.addLine(to: p(a - run * over, 1 + over))
            xGuides.move(to: p(a - run * 0.36, -0.36)); xGuides.addLine(to: p(xWidth - a + run * 0.36, 1.36))
        }

        glyphs = [
            Glyph(path: c, width: cWidth, guides: circle(p(0.5, 0.5), r)),
            Glyph(path: m, width: mWidth, guides: mGuides),
            Glyph(path: u, width: uWidth, guides: circle(p(u0 + ru, bowlY), ru)),
            Glyph(path: x, width: xWidth, guides: xGuides, clipsToBand: !roundCaps),
        ]
    }

    /// Each glyph's left edge, `gap` apart.
    func offsets(gap: CGFloat) -> [CGFloat] {
        var x: CGFloat = 0
        return glyphs.map { glyph in
            defer { x += glyph.width + gap }
            return x
        }
    }

    func width(gap: CGFloat) -> CGFloat {
        glyphs.reduce(0) { $0 + $1.width } + gap * CGFloat(glyphs.count - 1)
    }
}

/// A direction's wordmark and the tagline under it, with the shared entrance:
/// the tagline fades in once the mark has arrived.
private struct HeroStack<Mark: View>: View {
    var t: Double
    var taglineAt: Double
    var spacing: CGFloat = 18
    var name: String
    @ViewBuilder var mark: () -> Mark

    var body: some View {
        VStack(spacing: spacing) {
            mark()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "cmux"))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("welcome.wordmark.\(name.lowercased())")
            WelcomeHeroTagline()
                .opacity(IntroEase.out(IntroEase.seg(t, taglineAt, taglineAt + 0.3)))
        }
    }
}

// MARK: Lockup

/// The cmux lockup as the website sets it: the chevron (the launch chevron
/// glides into `slot`) and "cmux" in Geist SemiBold with tight tracking,
/// which comes in from a blur beside it.
struct WelcomeHeroLockup<Slot: View>: View {
    var t: Double
    @ViewBuilder var slot: () -> Slot

    static var markSize: CGFloat { 46 }

    var body: some View {
        let word = IntroEase.outQuint(IntroEase.seg(t, 0.2, 0.62))
        HeroStack(t: t, taglineAt: 0.4, spacing: 14, name: WelcomeHeroVariant.lockup.name) {
            HStack(spacing: 12) {
                slot()
                Text(verbatim: "cmux")
                    .font(Geist.semibold.font(size: 58))
                    // The website's tracking-tight: -0.025 em.
                    .tracking(-1.45)
                    .foregroundStyle(theme.colors.label)
                    .opacity(word)
                    .blur(radius: 6 * (1 - word))
                    .offset(x: -10 * (1 - word))
            }
            // The chevron's glow sits left of the slot: center the letters, not the box.
            .offset(x: -4)
        }
    }
}

// MARK: Site

/// The website's hero on a phone, left-aligned like the site: the app icon
/// tile springs in, "cmux" comes in from a blur beside it, then the line is
/// typed out in Geist with a caret that keeps blinking, as on cmux.com.
struct WelcomeHeroSite: View {
    var t: Double
    /// The caret blinks after typing (not under Reduce Motion or a frozen capture).
    var blinks: Bool

    private static var line: String { String(localized: "Your Macs, in your pocket") }
    private static var typeStart: Double { 0.62 }
    private static var typeStep: Double { 0.03 }

    var body: some View {
        let tile = E.spring(t, duration: 0.62, bounce: 0.3)
        let word = E.outQuint(E.seg(t, 0.22, 0.66))
        let count = Self.line.count
        let typed = !t.isFinite ? count : t < Self.typeStart ? 0 : min(count, Int((t - Self.typeStart) / Self.typeStep) + 1)
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                AppIconTile(size: 62)
                    .scaleEffect(0.55 + 0.45 * tile)
                    .opacity(E.out(E.seg(t, 0, 0.2)))
                Text(verbatim: "cmux")
                    .font(Geist.semibold.font(size: 44))
                    .tracking(-1.1)
                    .foregroundStyle(theme.colors.label)
                    .opacity(word)
                    .blur(radius: 8 * (1 - word))
                    .offset(x: -12 * (1 - word))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "cmux"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("welcome.wordmark.site")
            Group {
                if blinks && typed == count {
                    TimelineView(.periodic(from: .now, by: 0.53)) { context in
                        typedLine(typed: typed, caret: Int(context.date.timeIntervalSinceReferenceDate / 0.53).isMultiple(of: 2))
                    }
                } else {
                    typedLine(typed: typed, caret: t >= 0.4)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Self.line))
        }
        .frame(maxWidth: 440, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 36)
    }

    /// The whole line is laid out from the start (untyped letters are
    /// clear), so typing never reflows it.
    private func typedLine(typed: Int, caret: Bool) -> some View {
        let line = Self.line
        let split = line.index(line.startIndex, offsetBy: typed)
        var shown = AttributedString(String(line[..<split]))
        var bar = AttributedString("|")
        bar.foregroundColor = caret ? ChevronGradient.color(at: 0.4) : Color.clear
        var rest = AttributedString(String(line[split...]))
        rest.foregroundColor = Color.clear
        shown.append(bar)
        shown.append(rest)
        return Text(shown)
            .font(Geist.regular.font(size: 20, relativeTo: .title3))
            .foregroundStyle(theme.colors.label)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The app icon as the website shows it: a white rounded tile, the chevron in its gradient.
private struct AppIconTile: View {
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        shape
            .fill(LinearGradient(colors: [rgb(0xFFFFFF), rgb(0xEDEFF4)], startPoint: .top, endPoint: .bottom))
            .overlay { shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5) }
            .overlay {
                ChevronShape()
                    .fill(ChevronGradient.style)
                    .frame(width: size * 0.5 * Chevron.aspect, height: size * 0.5)
                    .offset(x: size * 0.04)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}

// MARK: Bloom

/// The chevron traces its own outline, fills, and blooms (a soft glow in its
/// gradient swells and settles), then "cmux" rises letter by letter out of a
/// blur on a light spring. The glow stays as a faint halo in dark mode; on
/// white it would read as a smudge, so in light mode it fades out.
struct WelcomeHeroBloom: View {
    var t: Double
    @Environment(\.colorScheme) private var colorScheme

    private static var letters: [String] { ["c", "m", "u", "x"] }
    private static var chevron: CGFloat { 44 }

    var body: some View {
        let trace = E.inOut(E.seg(t, 0.04, 0.5))
        let fill = E.out(E.seg(t, 0.38, 0.62))
        let pop = E.spring(t - 0.38, duration: 0.7, bounce: 0.38)
        let swell = E.out(E.seg(t, 0.36, 0.72))
        let settled = colorScheme == .dark ? 0.35 : 0
        let glow = swell * (1 - (1 - settled) * E.out(E.seg(t, 0.72, 1.3)))
        let h = Self.chevron
        HeroStack(t: t, taglineAt: 1.0, spacing: 16, name: WelcomeHeroVariant.bloom.name) {
            HStack(spacing: 16) {
                ZStack {
                    ChevronShape()
                        .trim(from: 0, to: trace)
                        .stroke(ChevronGradient.style, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .opacity(1 - fill)
                    ChevronShape()
                        .fill(ChevronGradient.style)
                        .opacity(fill)
                }
                .frame(width: h * Chevron.aspect, height: h)
                .scaleEffect(0.92 + 0.08 * pop)
                .background {
                    Circle()
                        .fill(RadialGradient(colors: [ChevronGradient.color(at: 0.5).opacity(0.6), .clear],
                                             center: .center, startRadius: 0, endRadius: 54))
                        .frame(width: 120, height: 120)
                        .scaleEffect(0.5 + 0.6 * swell)
                        .opacity(glow)
                        .allowsHitTesting(false)
                }
                HStack(spacing: 0) {
                    ForEach(Array(Self.letters.enumerated()), id: \.offset) { i, letter in
                        let start = 0.5 + 0.075 * Double(i)
                        let shown = E.out(E.seg(t, start, start + 0.42))
                        let rise = E.spring(t - start, duration: 0.7, bounce: 0.22)
                        Text(verbatim: letter)
                            .opacity(shown)
                            .blur(radius: 9 * (1 - shown))
                            .offset(y: 16 * (1 - rise))
                    }
                }
                .font(Geist.semibold.font(size: 58))
                .tracking(-1.45)
                .foregroundStyle(theme.colors.label)
            }
        }
    }
}

// MARK: Morph and Glide

/// The cursor's opening blink in Morph and Glide: it appears at 0.04 s, is on
/// for 60% of `cycle` and off for 40%, then holds on for a beat (11/30 of the
/// cycle) before the first letter. At Glide's 300 ms: off from 0.22 to 0.34 s,
/// typing from 0.45 s.
private struct OpeningBlink: Sendable {
    var cycle: Double

    var onAt: Double { 0.04 }
    var offAt: Double { onAt + 0.6 * cycle }
    var backAt: Double { offAt + 0.4 * cycle }
    var typeStart: Double { backAt + cycle * 11 / 30 }
    /// How much later than the 300 ms blink typing (and all that follows) starts.
    var delay: Double { typeStart - OpeningBlink(cycle: 0.3).typeStart }

    func isOff(_ t: Double) -> Bool { t >= offAt && t < backAt }
}

/// A block cursor in the chevron's gradient blinks, types "cmux" in Geist
/// SemiBold, blinks once more, then bends into the chevron as it flies back
/// to the front of the word: one shape, never a swap.
///
/// Glide (and its slower-blink variants) is Morph centered: the typed line
/// (letters and cursor) stays centered as it grows, so a lone cursor blinks
/// in the middle and the word types out from there; then, while the cursor
/// flies to the left of the word, the word slides right on the same curve,
/// and the lockup lands centered.
struct WelcomeHeroMorph: View {
    var t: Double
    var variant: WelcomeHeroVariant = .morph

    private static let word = GlyphOutline.make("cmux", font: Geist.semibold.ctFont(size: 100), tracking: -2.5)

    var body: some View {
        let word = Self.word
        let centered = variant != .morph
        let opening = OpeningBlink(cycle: variant.blinkCycle)
        // Everything after the opening blink runs this much later than at 300 ms.
        let later = opening.delay
        let xh = word.xHeight
        let chevronHeight = xh * 1.42
        let chevronWidth = chevronHeight * Chevron.aspect
        // The word's place in the settled lockup (the chevron is at x 0).
        let lockupWordX = chevronWidth + xh * 0.42
        // Glide centers on ink: its canvas ends at the x's last stroke, so the
        // settled lockup (chevron to x) sits exactly in the middle. Morph keeps
        // its frame (a little room after the x).
        let ink = word.path.boundingRect
        let width = centered ? lockupWordX + ink.maxX : lockupWordX + word.width + xh * 0.1
        let height = chevronHeight
        // Glide flies home over a little longer: two shapes move at once.
        let flight = centered ? 0.5 : 0.42
        HeroStack(t: t, taglineAt: (centered ? 1.45 : 1.3) + later, spacing: 22, name: variant.name) {
            Canvas { context, size in
                typealias E = IntroEase
                let scale = size.width / width
                context.scaleBy(x: scale, y: scale)
                let baseline = (height + xh) / 2
                let label = GraphicsContext.Shading.color(theme.colors.label.color)
                let blockWidth = xh * 0.6, blockHeight = xh * 1.2

                // Typing: one letter per 0.1 s; the cursor steps after each,
                // measured from the word's left edge.
                let typedAt = word.glyphs.indices.map { opening.typeStart + 0.1 * Double($0) }
                let step = xh * 0.1
                var cursorOffset: CGFloat = 0
                for (glyph, at) in zip(word.glyphs, typedAt) {
                    let p = CGFloat(E.outQuint(E.seg(t, at, at + 0.08)))
                    cursorOffset += (glyph.x + glyph.advance + step - cursorOffset) * p
                }
                let m = E.inOut(E.seg(t, 1.0 + later, 1.0 + later + flight))

                // Where the word is typed: at its lockup place (Morph), or with
                // the typed line's ink (first letter to the cursor's right edge)
                // centered in the canvas (Glide), which then slides into the
                // lockup with the cursor. Before the first letter the line is the
                // cursor alone; `min` lets the c's side bearing in continuously.
                let lineLeft = min(ink.minX, cursorOffset)
                let typingWordX = centered ? (width - lineLeft - cursorOffset - blockWidth) / 2 : lockupWordX
                let wordX = typingWordX + (lockupWordX - typingWordX) * CGFloat(m)

                // The cursor, drawn first: on its way home it passes behind
                // the letters, which stay crisp over it.
                // Off: the opening blink, and one quick blink once the word is typed.
                let blink = opening.isOff(t) || ((0.86 + later)..<(0.98 + later)).contains(t)
                if t >= opening.onAt, !blink {
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
        }
    }
}

// MARK: Decode

/// "cmux" in Geist Mono: each letter appears as terminal noise, scrambles,
/// then locks in left to right with a flash of the gradient; the chevron
/// blinks on first.
struct WelcomeHeroDecode: View {
    var t: Double

    private static var target: [String] { ["c", "m", "u", "x"] }
    private static var noise: [String] { ["<", ">", "/", "\\", "[", "]", "{", "}", "#", "$", "%", "&", "*", "+", "=", "?", "!", "0", "1", "_"] }

    /// The noise glyph each letter shows at `tick` (24 per second): each
    /// letter steps through the set at its own stride, so every one changes
    /// every tick, and no two show the same glyph at once.
    private static func scramble(tick: Int) -> [Int] {
        let count = noise.count
        let offsets = [3, 9, 14, 18], strides = [7, 11, 13, 17]
        var picked: [Int] = []
        for i in 0..<4 {
            var index = (offsets[i] + max(0, tick) * strides[i]) % count
            while picked.contains(index) { index = (index + 1) % count }
            picked.append(index)
        }
        return picked
    }

    var body: some View {
        // A tick is never negative: the noise index is taken modulo the set.
        let tick = t.isFinite ? max(0, Int(t * 24)) : 0
        let scramble = Self.scramble(tick: tick)
        let chevronOn = t >= 0.04 && !(0.1..<0.16).contains(t)
        HeroStack(t: t, taglineAt: 0.95, spacing: 16, name: WelcomeHeroVariant.decode.name) {
            HStack(spacing: 14) {
                ChevronShape()
                    .fill(ChevronGradient.style)
                    .frame(width: 40 * Chevron.aspect, height: 40)
                    .opacity(chevronOn ? 1 : 0)
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        let appear = 0.12 + 0.05 * Double(i)
                        let settle = 0.4 + 0.13 * Double(i)
                        let locked = t >= settle
                        let glyph = locked ? Self.target[i] : Self.noise[scramble[i]]
                        let flash = locked ? 1 - E.out(E.seg(t, settle, settle + 0.3)) : 0
                        Text(verbatim: glyph)
                            .foregroundStyle(locked ? theme.colors.label.color : theme.colors.label3.color)
                            .overlay {
                                Text(verbatim: glyph)
                                    .foregroundStyle(ChevronGradient.style)
                                    .opacity(flash)
                            }
                            .opacity(t >= appear ? 1 : 0)
                    }
                }
                .font(Geist.monoMedium.font(size: 54))
                .tracking(-2)
            }
        }
    }
}

// MARK: Shimmer

/// The lockup comes in from a blur, then one sheen in the chevron's gradient
/// sweeps across the letters, left to right, and is gone.
struct WelcomeHeroShimmer: View {
    var t: Double

    var body: some View {
        let appear = E.outQuint(E.seg(t, 0.04, 0.6))
        let sweep = CGFloat(E.inOut(E.seg(t, 0.5, 1.35)))
        HeroStack(t: t, taglineAt: 0.8, spacing: 16, name: WelcomeHeroVariant.shimmer.name) {
            lockup
                .overlay {
                    if sweep > 0 && sweep < 1 {
                        GeometryReader { proxy in
                            let band = proxy.size.width * 0.42
                            LinearGradient(stops: [
                                .init(color: ChevronGradient.color(at: 0).opacity(0), location: 0),
                                .init(color: ChevronGradient.color(at: 0), location: 0.35),
                                .init(color: ChevronGradient.color(at: 1), location: 0.65),
                                .init(color: ChevronGradient.color(at: 1).opacity(0), location: 1),
                            ], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + (proxy.size.width + band) * sweep)
                        }
                        .mask { lockup }
                        .allowsHitTesting(false)
                    }
                }
                .opacity(appear)
                .blur(radius: 10 * (1 - appear))
                .scaleEffect(0.95 + 0.05 * appear)
        }
    }

    private var lockup: some View {
        HStack(spacing: 12) {
            ChevronShape()
                .fill(ChevronGradient.style)
                .frame(width: 46 * Chevron.aspect, height: 46)
            Text(verbatim: "cmux")
                .font(Geist.semibold.font(size: 60))
                .tracking(-1.5)
                .foregroundStyle(theme.colors.label)
        }
    }
}

// MARK: Raster

/// "cmux" in Geist Black after the chevron, both cut into eight scan lines
/// across the x-height that thicken toward the baseline. The lines paint left
/// to right, top to bottom.
struct WelcomeHeroRaster: View {
    var t: Double

    private static let word = GlyphOutline.make("cmux", font: Geist.black.ctFont(size: 100), tracking: -2)
    private static var lines: Int { 8 }

    var body: some View {
        let word = Self.word
        let lines = Self.lines
        let xHeight = word.xHeight
        let ink = word.path.boundingRect
        let chevronWidth = xHeight * Chevron.aspect
        let gap = xHeight * 0.32
        let width = chevronWidth + gap + ink.width
        HeroStack(t: t, taglineAt: 0.7, spacing: 22, name: WelcomeHeroVariant.raster.name) {
            Canvas { context, size in
                typealias E = IntroEase
                let scale = size.width / width
                let pitch = size.height / CGFloat(lines)
                var scan = Path()
                for i in 0..<lines {
                    let start = 0.08 + 0.045 * Double(i)
                    let painted = E.outQuint(E.seg(t, start, start + 0.42))
                    guard painted > 0 else { continue }
                    let thickness = pitch * (0.34 + 0.5 * CGFloat(i) / CGFloat(lines - 1))
                    scan.addRect(CGRect(x: 0, y: CGFloat(i + 1) * pitch - thickness, width: size.width * painted, height: thickness))
                }
                guard !scan.isEmpty else { return }
                context.clip(to: scan)
                let chevron = Chevron.path(x: 0, y: 0, height: size.height)
                context.fill(chevron, with: ChevronGradient.shading(from: .zero, to: CGPoint(x: size.height * Chevron.aspect, y: 0)))
                let place = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: chevronWidth + gap - ink.minX, y: xHeight)
                context.fill(word.path.applying(place), with: .color(theme.colors.label.color))
            }
            .aspectRatio(width / xHeight, contentMode: .fit)
            .frame(maxWidth: 296)
            .padding(.horizontal, 40)
        }
    }
}

// MARK: Draft

/// A geometric monoline "cmux" drawn over its construction: the x-height,
/// middle and baseline guides run edge to edge with ticks at each glyph's
/// sides, circles sit behind the bowls and arches, the chevron shows its
/// triangle and angle. Guides grow first, then each letter is drawn in pen
/// order.
struct WelcomeHeroDraft: View {
    var t: Double

    private static var weight: CGFloat { 0.24 }
    private static let mono = Monoline(stroke: 0.24, roundCaps: false)

    var body: some View {
        let mono = Self.mono
        let weight = Self.weight
        HeroStack(t: t, taglineAt: 0.95, spacing: 8, name: WelcomeHeroVariant.draft.name) {
            Canvas { context, size in
                typealias E = IntroEase
                let lead = Chevron.aspect + 0.3
                let gap: CGFloat = 0.2
                let offsets = mono.offsets(gap: gap).map { lead + $0 }
                let total = lead + mono.width(gap: gap)
                let u = min(62, (size.width - 56) / total, size.height / 1.9)
                let ox = ((size.width - total * u) / 2).rounded()
                let oy = ((size.height - u) / 2).rounded()
                func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * u, y: oy + y * u) }
                func place(_ dx: CGFloat) -> CGAffineTransform { CGAffineTransform(a: u, b: 0, c: 0, d: u, tx: ox + dx * u, ty: oy) }
                let guide = GraphicsContext.Shading.color(theme.colors.label3.color)
                let hairline = StrokeStyle(lineWidth: 0.75)

                // 1. The x-height, middle and baseline guides grow from the middle out.
                let grow = E.outQuint(E.seg(t, 0, 0.45))
                if grow > 0 {
                    let mid = size.width / 2
                    for (y, dashed) in [(CGFloat(0), false), (0.5, true), (1, false)] {
                        var line = Path()
                        line.move(to: CGPoint(x: mid * (1 - grow), y: oy + y * u))
                        line.addLine(to: CGPoint(x: mid * (1 + grow), y: oy + y * u))
                        context.stroke(line, with: guide, style: dashed ? StrokeStyle(lineWidth: 0.75, dash: [3, 4]) : hairline)
                    }
                    var ticks = Path()
                    // Ticks at the glyphs' sides, inside the mark (the labels sit at the ends).
                    let sides: [CGFloat] = zip(offsets, mono.glyphs).flatMap { x, glyph in [x, x + glyph.width] }
                    let edges: [CGFloat] = [Chevron.aspect] + sides.dropLast()
                    for x in edges {
                        ticks.move(to: p(x, -0.16)); ticks.addLine(to: p(x, 0))
                        ticks.move(to: p(x, 1)); ticks.addLine(to: p(x, 1.16))
                    }
                    var faded = context
                    faded.opacity = grow
                    faded.stroke(ticks, with: guide, style: hairline)
                    faded.draw(draftLabel("x-height"), at: CGPoint(x: 10, y: oy - 3), anchor: .bottomLeading)
                    faded.draw(draftLabel("baseline"), at: CGPoint(x: 10, y: oy + u + 3), anchor: .topLeading)
                }

                // 2. The construction: circles, the x's diagonal, the chevron's triangle and angle.
                let construct = E.out(E.seg(t, 0.15, 0.65))
                if construct > 0 {
                    var shapes = zip(offsets, mono.glyphs).map { $1.guides.applying(place($0)) }
                    var triangle = Path()
                    triangle.addLines([p(0, 0), p(Chevron.aspect, 0.5), p(0, 1)])
                    triangle.closeSubpath()
                    shapes.append(triangle)
                    var angle = Path()
                    angle.addSampledArc(center: p(Chevron.aspect, 0.5), radius: 0.27 * u, from: 145.2, to: 214.8)
                    shapes.append(angle)
                    for shape in shapes where !shape.isEmpty {
                        context.stroke(shape.trimmedPath(from: 0, to: construct), with: guide, style: hairline)
                    }
                }

                // 3. The chevron settles in, in its gradient.
                let chevron = E.out(E.seg(t, 0.3, 0.55))
                if chevron > 0 {
                    var c = context
                    c.opacity = chevron
                    c.fill(Chevron.path(x: ox - 6 * (1 - chevron), y: oy, height: u),
                           with: ChevronGradient.shading(from: p(0, 0), to: p(Chevron.aspect, 0)))
                }

                // 4. The letters, one after another, each in pen order.
                let pen = StrokeStyle(lineWidth: weight * u, lineCap: .butt, lineJoin: .round)
                for (i, (x, glyph)) in zip(offsets, mono.glyphs).enumerated() {
                    let start = 0.4 + 0.11 * Double(i)
                    let drawn = E.inOut(E.seg(t, start, start + 0.4))
                    guard drawn > 0 else { continue }
                    let stroke = glyph.path.applying(place(x)).trimmedPath(from: 0, to: drawn)
                    var letter = context
                    if glyph.clipsToBand {
                        letter.clip(to: Path(CGRect(x: ox + (x - 0.5) * u, y: oy, width: (glyph.width + 1) * u, height: u)))
                    }
                    letter.stroke(stroke, with: .color(theme.colors.label.color), style: pen)
                }
            }
            .frame(height: 118)
        }
    }
}

/// Draft's guide labels: 9 pt SF Mono in the guides' gray.
private func draftLabel(_ text: String) -> Text {
    Text(verbatim: text)
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(theme.colors.label3.color)
}

// MARK: Keys

/// Five keycaps: the chevron key, then c, m, u, x. The caps rise in, the four
/// letters are typed in order, then the chevron key is pressed and lights up
/// in the gradient.
struct WelcomeHeroKeys: View {
    var t: Double
    @Environment(\.colorScheme) private var colorScheme

    private static let legends = ["c", "m", "u", "x"].map { GlyphOutline.make($0, font: Geist.regular.ctFont(size: 27)) }

    var body: some View {
        let dark = colorScheme == .dark
        let legends = Self.legends
        let design = KeyCap.canvas
        HeroStack(t: t, taglineAt: 1.0, spacing: 14, name: WelcomeHeroVariant.keys.name) {
            Canvas { context, size in
                typealias E = IntroEase
                let scale = size.width / design.width
                context.scaleBy(x: scale, y: scale)
                let top = dark ? [rgb(0x3D3D40), rgb(0x2F2F32)] : [rgb(0xFFFFFF), rgb(0xF4F4F6)]
                let side = dark ? rgb(0x161618) : rgb(0xC9C9CE)
                let accentSide = dark ? rgb(0x2C2A8F) : rgb(0x3B39C9)
                let edge = dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08)
                let legend = dark ? rgb(0xF5F5F7) : rgb(0x1A1A1A)
                let lit = E.out(E.seg(t, 0.92, 1.12))
                for i in 0..<5 {
                    let shown = E.out(E.seg(t, 0.04 * Double(i), 0.04 * Double(i) + 0.28))
                    guard shown > 0 else { continue }
                    let struck = i == 0 ? 0.88 : 0.34 + 0.11 * Double(i - 1)
                    let depth = KeyCap.lip * 0.9 * KeyCap.press(t - struck)
                    let x = 12 + CGFloat(i) * (KeyCap.key + KeyCap.gap)
                    let y = 6 + 6 * CGFloat(1 - shown)
                    let base = Path(roundedRect: CGRect(x: x, y: y + KeyCap.lip, width: KeyCap.key, height: KeyCap.key),
                                    cornerRadius: KeyCap.radius, style: .continuous)
                    let capRect = CGRect(x: x, y: y + depth, width: KeyCap.key, height: KeyCap.key)
                    let cap = Path(roundedRect: capRect, cornerRadius: KeyCap.radius, style: .continuous)
                    let accent = i == 0 ? lit : 0

                    var keycap = context
                    keycap.opacity = shown
                    keycap.addFilter(.shadow(color: .black.opacity(dark ? 0.5 : 0.12), radius: 6, x: 0, y: 6))
                    keycap.drawLayer { k in
                        k.fill(base, with: .color(side))
                        k.fill(cap, with: .linearGradient(Gradient(colors: top),
                                                          startPoint: CGPoint(x: capRect.midX, y: capRect.minY),
                                                          endPoint: CGPoint(x: capRect.midX, y: capRect.maxY)))
                        if accent > 0 {
                            k.opacity = accent
                            k.fill(base, with: .color(accentSide))
                            k.fill(cap, with: ChevronGradient.shading(from: capRect.origin, to: CGPoint(x: capRect.maxX, y: capRect.maxY)))
                            k.opacity = 1
                        }
                        let rim = Path(roundedRect: capRect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: KeyCap.radius - 0.5, style: .continuous)
                        k.stroke(rim, with: .color(accent > 0.5 ? Color.white.opacity(0.18) : edge), lineWidth: 1)
                    }

                    var mark = context
                    mark.opacity = shown
                    if i == 0 {
                        let chevron = Chevron.path(x: capRect.midX - 0.36 * 20, y: capRect.midY - 10, height: 20)
                        mark.fill(chevron, with: .color(legend.opacity(1 - accent)))
                        if accent > 0 { mark.fill(chevron, with: .color(.white.opacity(accent))) }
                    } else {
                        let glyph = legends[i - 1]
                        let ink = glyph.path.boundingRect
                        let at = CGAffineTransform(translationX: capRect.midX - ink.midX, y: capRect.midY + glyph.xHeight / 2)
                        mark.fill(glyph.path.applying(at), with: .color(legend))
                    }
                }
            }
            .aspectRatio(design.width / design.height, contentMode: .fit)
            .frame(maxWidth: design.width)
            .padding(.horizontal, 20)
        }
    }
}

/// Keys' metrics, in points at the design size, and how a key moves.
private enum KeyCap {
    static let key: CGFloat = 58
    static let gap: CGFloat = 9
    static let lip: CGFloat = 5
    static let radius: CGFloat = 13
    static let canvas = CGSize(width: 5 * key + 4 * gap + 24, height: key + lip + 24)

    /// How far a key is down (0 at rest, 1 bottomed out) `u` seconds after it
    /// is struck: down in 50 ms, then back up on a light spring.
    static func press(_ u: Double) -> CGFloat {
        guard u > 0 else { return 0 }
        if u < 0.05 { return CGFloat(IntroEase.out(u / 0.05)) }
        let back = u - 0.05
        guard back < 0.32 else { return 0 }
        return CGFloat(1 - IntroEase.spring(back, duration: 0.32, bounce: 0.25))
    }
}

// MARK: Circuit

/// "cmux" as circuit traces: 45° corners, hollow pads at the ends, a via
/// where the x crosses, the chevron's trace in the gradient. Each letter's
/// traces run from their first pad to the last, left to right.
struct WelcomeHeroCircuit: View {
    var t: Double

    private struct Trace: Sendable {
        var points: [CGPoint]
        var startPad = true
        var endPad = true
    }

    private struct Glyph: Sendable {
        var x: CGFloat
        var traces: [Trace]
        var via: CGPoint?
    }

    private static let glyphs: [Glyph] = {
        let k: CGFloat = 0.24
        func trace(_ points: [(CGFloat, CGFloat)], startPad: Bool = true) -> Trace {
            Trace(points: points.map { CGPoint(x: $0.0, y: $0.1) }, startPad: startPad)
        }
        return [
            Glyph(x: 0, traces: [trace([(0, 0), (0.62, 0.5), (0, 1)])]),
            Glyph(x: 1.04, traces: [trace([(0.7, 0), (k, 0), (0, k), (0, 1 - k), (k, 1), (0.7, 1)])]),
            Glyph(x: 2.04, traces: [
                trace([(0, 1), (0, k), (k, 0), (0.56 - k, 0), (0.56, k), (0.56, 1)]),
                trace([(0.56, k), (0.56 + k, 0), (1.12 - k, 0), (1.12, k), (1.12, 1)], startPad: false),
            ]),
            Glyph(x: 3.46, traces: [trace([(0, 0), (0, 1 - k), (k, 1), (0.7 - k, 1), (0.7, 1 - k), (0.7, 0)])]),
            Glyph(x: 4.46, traces: [trace([(0, 0), (0.74, 1)]), trace([(0.74, 0), (0, 1)])], via: CGPoint(x: 0.37, y: 0.5)),
        ]
    }()
    private static var width: CGFloat { 5.2 }
    private static var margin: CGFloat { 0.12 }

    var body: some View {
        let glyphs = Self.glyphs
        let width = Self.width + 2 * Self.margin
        let height = 1 + 2 * Self.margin
        let margin = Self.margin
        HeroStack(t: t, taglineAt: 0.75, spacing: 20, name: WelcomeHeroVariant.circuit.name) {
            Canvas { context, size in
                typealias E = IntroEase
                let u = size.width / width
                let o = margin * u
                let line = 0.085 * u
                let ink = GraphicsContext.Shading.color(theme.colors.label.color)
                let board = GraphicsContext.Shading.color(theme.colors.bg.color)
                let accent = ChevronGradient.shading(from: CGPoint(x: o, y: 0), to: CGPoint(x: o + 0.62 * u, y: 0))
                var pads: [(center: CGPoint, scale: Double, shading: GraphicsContext.Shading)] = []
                var vias: [(center: CGPoint, scale: Double)] = []
                for (g, glyph) in glyphs.enumerated() {
                    let start = 0.08 + 0.12 * Double(g)
                    let drawn = E.out(E.seg(t, start, start + 0.36))
                    guard drawn > 0 else { continue }
                    let shading = g == 0 ? accent : ink
                    func point(_ q: CGPoint) -> CGPoint { CGPoint(x: o + (glyph.x + q.x) * u, y: o + q.y * u) }
                    for trace in glyph.traces {
                        var path = Path()
                        path.addLines(trace.points.map(point))
                        context.stroke(path.trimmedPath(from: 0, to: drawn), with: shading,
                                       style: StrokeStyle(lineWidth: line, lineCap: .butt, lineJoin: .miter))
                        if trace.startPad, let first = trace.points.first {
                            pads.append((point(first), E.outBack(E.seg(t, start, start + 0.16)), shading))
                        }
                        if trace.endPad, let last = trace.points.last {
                            pads.append((point(last), E.outBack(E.seg(t, start + 0.3, start + 0.46)), shading))
                        }
                    }
                    if let via = glyph.via { vias.append((point(via), E.outBack(E.seg(t, start + 0.18, start + 0.34)))) }
                }
                for pad in pads where pad.scale > 0 {
                    let r = 0.075 * u * pad.scale
                    let ring = Path(ellipseIn: CGRect(x: pad.center.x - r, y: pad.center.y - r, width: 2 * r, height: 2 * r))
                    context.fill(ring, with: board)
                    context.stroke(ring, with: pad.shading, lineWidth: line * 0.8 * pad.scale)
                }
                for via in vias where via.scale > 0 {
                    let r = 0.094 * u * via.scale, hole = 0.034 * u * via.scale
                    context.fill(Path(ellipseIn: CGRect(x: via.center.x - r, y: via.center.y - r, width: 2 * r, height: 2 * r)), with: ink)
                    context.fill(Path(ellipseIn: CGRect(x: via.center.x - hole, y: via.center.y - hole, width: 2 * hole, height: 2 * hole)), with: board)
                }
            }
            .aspectRatio(width / height, contentMode: .fit)
            .frame(maxWidth: 326)
            .padding(.horizontal, 32)
        }
    }
}

// MARK: Tube

/// The monoline drawn as one hollow tube: the chevron in the gradient, the
/// letters in the label colour, lit in dark mode with a soft glow. The
/// letters switch on in turn with one flicker each, like a sign.
struct WelcomeHeroTube: View {
    var t: Double
    @Environment(\.colorScheme) private var colorScheme

    private static var outer: CGFloat { 0.17 }
    private static var inner: CGFloat { 0.07 }
    private static let mono = Monoline(stroke: 0.17, roundCaps: true)
    private static var padding: CGFloat { 0.3 }

    var body: some View {
        let dark = colorScheme == .dark
        let outer = Self.outer, inner = Self.inner, padding = Self.padding
        var prompt = Path()
        prompt.addLines([CGPoint(x: outer / 2, y: outer / 2), CGPoint(x: 0.62 - outer / 2, y: 0.5), CGPoint(x: outer / 2, y: 1 - outer / 2)])
        let lead: CGFloat = 0.62 + 0.36
        let letters = Self.mono.offsets(gap: 0.24).map { lead + $0 }
        let pieces = [(prompt, CGFloat(0))] + zip(Self.mono.glyphs, letters).map { ($0.path, $1) }
        let total = lead + Self.mono.width(gap: 0.24)
        let width = total + 2 * padding
        let height = 1 + 2 * padding
        return HeroStack(t: t, taglineAt: 0.8, spacing: 8, name: WelcomeHeroVariant.tube.name) {
            Canvas { context, size in
                typealias E = IntroEase
                let u = size.width / width
                let ox = padding * u, oy = padding * u
                let ink = GraphicsContext.Shading.color(theme.colors.label.color)
                let accent = ChevronGradient.shading(from: CGPoint(x: ox, y: 0), to: CGPoint(x: ox + 0.62 * u, y: 0))
                let wall = StrokeStyle(lineWidth: outer * u, lineCap: .round, lineJoin: .round)
                let bore = StrokeStyle(lineWidth: inner * u, lineCap: .round, lineJoin: .round)
                for (g, piece) in pieces.enumerated() {
                    let local = t - (0.12 + 0.13 * Double(g))
                    let on = TubeLight.ignite(local)
                    guard on > 0 else { continue }
                    let path = piece.0.applying(CGAffineTransform(a: u, b: 0, c: 0, d: u, tx: ox + piece.1 * u, ty: oy))
                    let shading = g == 0 ? accent : ink
                    if dark {
                        let warm = on * E.out(E.seg(local, 0.11, 0.6))
                        if warm > 0 {
                            var glow = context
                            glow.opacity = 0.7 * warm
                            glow.addFilter(.blur(radius: 0.14 * u))
                            glow.stroke(path, with: shading, style: StrokeStyle(lineWidth: outer * u * 1.1, lineCap: .round, lineJoin: .round))
                        }
                    }
                    var tube = context
                    tube.opacity = on
                    tube.drawLayer { layer in
                        layer.stroke(path, with: shading, style: wall)
                        layer.blendMode = .destinationOut
                        layer.stroke(path, with: .color(.black), style: bore)
                    }
                }
            }
            .aspectRatio(width / height, contentMode: .fit)
            .frame(maxWidth: 344)
            .padding(.horizontal, 22)
        }
    }
}

/// How Tube's letters switch on.
private enum TubeLight {
    /// A letter's brightness `u` seconds after it switches on: on, a dip, on.
    static func ignite(_ u: Double) -> Double {
        if u < 0 { return 0 }
        if u < 0.05 { return 0.85 }
        if u < 0.11 { return 0.2 }
        return 0.55 + 0.45 * IntroEase.out(IntroEase.seg(u, 0.11, 0.24))
    }
}

// MARK: Picker

#if DEBUG
/// The prototype picker (prototype skill PICKER.md, in SwiftUI): a dark glass
/// panel at the top, two rows (round 4's Geist directions, then round 3's
/// drawn marks), because the sign-in rows fill the bottom. Tapping an item
/// switches at once; only the highlight slides (250 ms, strong ease-out).
struct WelcomeHeroPicker: View {
    @Binding var selection: WelcomeHeroVariant
    var replay: () -> Void
    @Namespace private var highlight

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(WelcomeHeroVariant.pickerRows[0]) { item($0) }
            }
            HStack(spacing: 2) {
                ForEach(WelcomeHeroVariant.pickerRows[1]) { item($0) }
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 3)
                Button(action: replay) {
                    Text(verbatim: "↻").font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 9).frame(height: 26)
                }
                .buttonStyle(.cmuxPressFill)
                .accessibilityLabel(Text(verbatim: "Replay"))
            }
            HStack(spacing: 2) {
                ForEach(WelcomeHeroVariant.pickerRows[2]) { item($0) }
            }
        }
        .padding(4)
        .background(Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255).opacity(0.82),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
        .shadow(color: .black.opacity(0.24), radius: 12, y: 8)
        .animation(Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.25).unlessReduceMotion, value: selection)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(.large)
    }

    private func item(_ variant: WelcomeHeroVariant) -> some View {
        Button {
            selection = variant
            UserDefaults.standard.set(variant.rawValue, forKey: WelcomeHeroVariant.storeKey)
        } label: {
            Text(verbatim: variant.label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(selection == variant ? 1 : 0.55))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background {
                    if selection == variant {
                        Capsule().fill(.white.opacity(0.12))
                            .matchedGeometryEffect(id: "highlight", in: highlight)
                    }
                }
        }
        .buttonStyle(.cmuxPressFill)
        .accessibilityAddTraits(selection == variant ? .isSelected : [])
        .accessibilityIdentifier("welcome.hero.\(variant.name.lowercased())")
    }
}
#endif
#endif

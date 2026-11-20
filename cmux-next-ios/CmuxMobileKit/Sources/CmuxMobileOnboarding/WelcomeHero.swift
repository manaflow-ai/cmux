#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Prototype, round 2: directions for the welcome's top section, after
/// Conductor's sign-in (one wordmark in the middle, one gray line under it,
/// nothing at the top). The sign-in rows and the legal line are the same in
/// every variant. `now` is the shipped design: Release shows it until a
/// direction is picked; then the picked one replaces it and the rest of this
/// file, the picker and the enum go (prototype skill, phase 6).
enum WelcomeHeroVariant: Int, CaseIterable, Identifiable, Sendable {
    /// Today: lockup at the top, Mac and phone line art, one line.
    case now
    /// The cmux lockup, large, alone in the middle.
    case lockup
    /// A shell prompt: the chevron, "cmux" in SF Mono, a block cursor.
    case prompt
    /// "cmux" drawn in terminal cells, the chevron leading in its gradient.
    case cells
    /// A figlet-style terminal banner (block letters with a line shadow).
    case banner
    /// Type only: "cmux" in SF Pro Expanded Black, edge to edge.
    case poster

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .now: "Now"
        case .lockup: "Lockup"
        case .prompt: "Prompt"
        case .cells: "Cells"
        case .banner: "Banner"
        case .poster: "Poster"
        }
    }

    /// The variants the picker offers (today's design is in the report, not the pill).
    static let directions: [WelcomeHeroVariant] = [.lockup, .prompt, .cells, .banner, .poster]

    /// The launch screen's chevron glides into this variant's own chevron;
    /// otherwise it dissolves in place while the wordmark comes in.
    var carriesMark: Bool {
        switch self {
        case .now, .lockup, .prompt: true
        case .cells, .banner, .poster: false
        }
    }

    /// How long the variant's entrance runs (the welcome's timeline stays awake that long).
    var entranceDuration: Double {
        switch self {
        case .now: WelcomeArt.introDuration + 0.1
        case .lockup, .poster: 0.9
        case .prompt: 1.2
        case .cells, .banner: 1.0
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

    static let storeKey = "cmuxMobile.prototype.welcomeHero.v2"
}

/// The tagline every direction shares, so the comparison is about the mark.
struct WelcomeHeroTagline: View {
    var body: some View {
        Text("Your Macs, in your pocket")
            .font(.body)
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

/// The cmux lockup, large and alone: the launch chevron glides into `slot`,
/// the wordmark slides in beside it.
struct WelcomeHeroLockup<Slot: View>: View {
    var t: Double
    @ViewBuilder var slot: () -> Slot

    static var markSize: CGFloat { 46 }

    var body: some View {
        let word = IntroEase.outQuint(IntroEase.seg(t, 0.2, 0.6))
        HeroStack(t: t, taglineAt: 0.35, spacing: 16, name: WelcomeHeroVariant.lockup.name) {
            HStack(spacing: 12) {
                slot()
                Text(verbatim: "cmux")
                    .font(.system(size: 56, weight: .bold))
                    .tracking(-1.6)
                    .foregroundStyle(theme.colors.label)
                    .opacity(word)
                    .offset(x: -10 * (1 - word))
            }
            // The chevron's glow sits left of the slot: center the letters, not the box.
            .offset(x: -4)
        }
    }
}

// MARK: Prompt

/// A shell prompt: the chevron (the launch mark glides into `slot`), "cmux"
/// typed one letter at a time in SF Mono, and a block cursor that then blinks.
struct WelcomeHeroPrompt<Slot: View>: View {
    var t: Double
    /// The cursor blinks after typing (not under Reduce Motion or a frozen capture).
    var blinks: Bool
    @ViewBuilder var slot: () -> Slot

    static var markSize: CGFloat { 38 }
    // Computed: a generic type cannot hold static stored properties.
    private static var word: [Character] { Array("cmux") }
    private static var typeStart: Double { 0.45 }
    private static var typeStep: Double { 0.075 }
    private static var cursor: Color { Color(red: 0.18, green: 0.56, blue: 1.0) }

    var body: some View {
        let typed = Self.word.indices.filter { t >= Self.typeStart + Double($0) * Self.typeStep }.count
        HeroStack(t: t, taglineAt: 0.8, spacing: 18, name: WelcomeHeroVariant.prompt.name) {
            HStack(spacing: 14) {
                slot()
                HStack(spacing: 0) {
                    ForEach(Array(0...Self.word.count), id: \.self) { i in
                        // One fixed cell per letter plus one for the resting
                        // cursor, so typing never moves anything.
                        ZStack {
                            Text(verbatim: i < Self.word.count ? String(Self.word[i]) : "x")
                                .opacity(i < typed ? 1 : 0)
                            if i == typed { cursorBlock(typing: typed < Self.word.count) }
                        }
                    }
                }
                .font(.system(size: 46, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.colors.label)
            }
            // Optical center: the empty cursor cell is weightless.
            .offset(x: 10)
        }
    }

    @ViewBuilder
    private func cursorBlock(typing: Bool) -> some View {
        if blinks && !typing {
            TimelineView(.periodic(from: .now, by: 0.53)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 0.53).isMultiple(of: 2)
                block.opacity(on ? 1 : 0)
            }
        } else {
            block.opacity(t >= Self.typeStart - 0.15 ? 1 : 0)
        }
    }

    private var block: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Self.cursor)
            .padding(.vertical, 6)
            .padding(.horizontal, 1)
    }
}

// MARK: Cells

/// "cmux" set in terminal cells on a 5-row grid (lowercase, x-height only),
/// the chevron leading in the icon's gradient. The columns light left to right.
struct WelcomeHeroCells: View {
    var t: Double

    /// One column per entry; nil is an empty spacer column.
    private static let columns: [(glyph: Character, bits: [Bool])?] = {
        let glyphs: [Character: [String]] = [
            ">": ["#..", ".#.", "..#", ".#.", "#.."],
            "c": [".###", "#...", "#...", "#...", ".###"],
            "m": ["####.", "#.#.#", "#.#.#", "#.#.#", "#.#.#"],
            "u": ["#..#", "#..#", "#..#", "#..#", ".###"],
            "x": ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
        ]
        var out: [(glyph: Character, bits: [Bool])?] = []
        for (n, ch) in Array(">cmux").enumerated() {
            if n == 1 { out += [nil, nil] } else if n > 1 { out.append(nil) }
            let rows = glyphs[ch] ?? []
            for c in 0..<(rows.first?.count ?? 0) {
                out.append((ch, rows.map { Array($0)[c] == "#" }))
            }
        }
        return out
    }()

    var body: some View {
        let columns = Self.columns
        HeroStack(t: t, taglineAt: 0.6, spacing: 20, name: WelcomeHeroVariant.cells.name) {
            Canvas { context, size in
                let pitch = size.width / CGFloat(columns.count)
                let cell = pitch * 0.84
                let label = context.resolve(GraphicsContext.Shading.color(theme.colors.label.color))
                for (x, column) in columns.enumerated() {
                    guard let column else { continue }
                    let lit = IntroEase.out(IntroEase.seg(t, 0.1 + Double(x) * 0.016, 0.24 + Double(x) * 0.016))
                    guard lit > 0 else { continue }
                    let shading: GraphicsContext.Shading = column.glyph == ">" ? .color(ChevronGradient.color(at: Double(x) / 2)) : label
                    for (y, on) in column.bits.enumerated() where on {
                        let rect = CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch, width: cell, height: cell)
                        context.opacity = lit
                        context.fill(Path(roundedRect: rect, cornerRadius: pitch * 0.16, style: .continuous), with: shading)
                    }
                }
            }
            .aspectRatio(CGFloat(columns.count) / 5, contentMode: .fit)
            .frame(maxWidth: 300)
            .padding(.horizontal, 40)
        }
    }
}

// MARK: Banner

/// A terminal banner (figlet "ANSI Shadow"): block letters with a double-line
/// shadow, drawn cell by cell (no font fallback can misalign it). Rows print
/// top to bottom.
struct WelcomeHeroBanner: View {
    var t: Double

    private static let rows: [[Character]] = [
        " ██████╗███╗   ███╗██╗   ██╗██╗  ██╗",
        "██╔════╝████╗ ████║██║   ██║╚██╗██╔╝",
        "██║     ██╔████╔██║██║   ██║ ╚███╔╝ ",
        "██║     ██║╚██╔╝██║██║   ██║ ██╔██╗ ",
        "╚██████╗██║ ╚═╝ ██║╚██████╔╝██╔╝ ██╗",
        " ╚═════╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝",
    ].map(Array.init)

    var body: some View {
        let rows = Self.rows
        let columns = rows.map(\.count).max() ?? 1
        HeroStack(t: t, taglineAt: 0.55, spacing: 22, name: WelcomeHeroVariant.banner.name) {
            Canvas { context, size in
                let w = size.width / CGFloat(columns)
                let h = size.height / CGFloat(rows.count)
                let gap = w * 0.2
                let stroke = StrokeStyle(lineWidth: max(1, w * 0.13), lineCap: .square)
                let fill = context.resolve(GraphicsContext.Shading.color(theme.colors.label.color))
                let shadow = context.resolve(GraphicsContext.Shading.color(theme.colors.label3.color))
                for (r, row) in rows.enumerated() {
                    let shown = IntroEase.out(IntroEase.seg(t, 0.1 + Double(r) * 0.06, 0.2 + Double(r) * 0.06))
                    guard shown > 0 else { continue }
                    context.opacity = shown
                    for (c, ch) in row.enumerated() {
                        let x = CGFloat(c) * w, y = CGFloat(r) * h
                        let cx = x + w / 2, cy = y + h / 2
                        if ch == "█" {
                            // A hair wider so neighbouring blocks join with no seam.
                            context.fill(Path(CGRect(x: x, y: y, width: w + 0.4, height: h + 0.4)), with: fill)
                            continue
                        }
                        var p = Path()
                        func line(_ a: CGPoint, _ b: CGPoint) { p.move(to: a); p.addLine(to: b) }
                        switch ch {
                        case "═":
                            line(CGPoint(x: x, y: cy - gap), CGPoint(x: x + w, y: cy - gap))
                            line(CGPoint(x: x, y: cy + gap), CGPoint(x: x + w, y: cy + gap))
                        case "║":
                            line(CGPoint(x: cx - gap, y: y), CGPoint(x: cx - gap, y: y + h))
                            line(CGPoint(x: cx + gap, y: y), CGPoint(x: cx + gap, y: y + h))
                        case "╗":
                            line(CGPoint(x: x, y: cy - gap), CGPoint(x: cx + gap, y: cy - gap)); line(CGPoint(x: cx + gap, y: cy - gap), CGPoint(x: cx + gap, y: y + h))
                            line(CGPoint(x: x, y: cy + gap), CGPoint(x: cx - gap, y: cy + gap)); line(CGPoint(x: cx - gap, y: cy + gap), CGPoint(x: cx - gap, y: y + h))
                        case "╔":
                            line(CGPoint(x: x + w, y: cy - gap), CGPoint(x: cx - gap, y: cy - gap)); line(CGPoint(x: cx - gap, y: cy - gap), CGPoint(x: cx - gap, y: y + h))
                            line(CGPoint(x: x + w, y: cy + gap), CGPoint(x: cx + gap, y: cy + gap)); line(CGPoint(x: cx + gap, y: cy + gap), CGPoint(x: cx + gap, y: y + h))
                        case "╝":
                            line(CGPoint(x: x, y: cy + gap), CGPoint(x: cx + gap, y: cy + gap)); line(CGPoint(x: cx + gap, y: cy + gap), CGPoint(x: cx + gap, y: y))
                            line(CGPoint(x: x, y: cy - gap), CGPoint(x: cx - gap, y: cy - gap)); line(CGPoint(x: cx - gap, y: cy - gap), CGPoint(x: cx - gap, y: y))
                        case "╚":
                            line(CGPoint(x: x + w, y: cy + gap), CGPoint(x: cx - gap, y: cy + gap)); line(CGPoint(x: cx - gap, y: cy + gap), CGPoint(x: cx - gap, y: y))
                            line(CGPoint(x: x + w, y: cy - gap), CGPoint(x: cx + gap, y: cy - gap)); line(CGPoint(x: cx + gap, y: cy - gap), CGPoint(x: cx + gap, y: y))
                        default:
                            continue
                        }
                        context.stroke(p, with: shadow, style: stroke)
                    }
                }
            }
            // Terminal cells are twice as tall as wide.
            .aspectRatio(CGFloat(columns) / (CGFloat(rows.count) * 2), contentMode: .fit)
            .frame(maxWidth: 316)
            .padding(.horizontal, 36)
        }
    }
}

// MARK: Poster

/// Type only: "cmux" in SF Pro Expanded Black, as wide as the screen allows.
struct WelcomeHeroPoster: View {
    var t: Double

    var body: some View {
        let p = IntroEase.outQuint(IntroEase.seg(t, 0.1, 0.6))
        HeroStack(t: t, taglineAt: 0.4, spacing: 10, name: WelcomeHeroVariant.poster.name) {
            Text(verbatim: "cmux")
                .font(.system(size: 132, weight: .black).width(.expanded))
                .tracking(-5)
                .foregroundStyle(theme.colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 24)
                .opacity(p)
                .offset(y: 14 * (1 - p))
        }
    }
}

// MARK: Picker

#if DEBUG
/// The prototype picker (prototype skill PICKER.md, in SwiftUI): a dark glass
/// pill, here at the top because the sign-in rows fill the bottom. Tapping an
/// item switches at once; only the highlight slides (250 ms, strong ease-out).
struct WelcomeHeroPicker: View {
    @Binding var selection: WelcomeHeroVariant
    var replay: () -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WelcomeHeroVariant.directions) { variant in
                Button {
                    selection = variant
                    UserDefaults.standard.set(variant.rawValue, forKey: WelcomeHeroVariant.storeKey)
                } label: {
                    Text(verbatim: variant.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(selection == variant ? 1 : 0.55))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
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
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 4)
            Button(action: replay) {
                Text(verbatim: "↻").font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 10).frame(height: 28)
            }
            .buttonStyle(.cmuxPressFill)
            .accessibilityLabel(Text(verbatim: "Replay"))
        }
        .padding(4)
        .background(Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255).opacity(0.82), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1) }
        .shadow(color: .black.opacity(0.24), radius: 12, y: 8)
        .animation(Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.25).unlessReduceMotion, value: selection)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(.large)
    }
}
#endif
#endif

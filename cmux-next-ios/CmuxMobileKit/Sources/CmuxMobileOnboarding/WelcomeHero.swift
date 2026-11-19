#if os(iOS)
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Prototype: alternatives for the welcome's top section (everything above the
/// sign-in rows). The rows and the legal line are the same in every variant.
/// `Now` is the shipped design, kept for comparison. Pick one, then the others,
/// the picker and this enum go (prototype skill, phase 6).
enum WelcomeHeroVariant: Int, CaseIterable, Identifiable, Sendable {
    /// Today: lockup, Mac and phone line art, one line.
    case now
    /// A live agent session on the Mac, as the hero.
    case terminal
    /// Big left-aligned type, no picture.
    case statement
    /// The app icon's chevron, large and centered, glowing.
    case mark
    /// What reaches the phone: agent notifications.
    case feed

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .now: "Now"
        case .terminal: "Terminal"
        case .statement: "Statement"
        case .mark: "Mark"
        case .feed: "Feed"
        }
    }

    /// Where the cmux lockup sits.
    enum Lockup { case topCenter, topLeading, inHero }

    var lockup: Lockup {
        switch self {
        case .now, .terminal, .feed: .topCenter
        case .statement: .topLeading
        case .mark: .inHero
        }
    }

    /// The variant this process shows: `-cmux-mobile-welcome-hero <name|n>`
    /// (DEBUG; pins it and hides the picker), else the picker's last choice,
    /// else `now`. Release always shows `now`.
    static var launchChoice: (variant: WelcomeHeroVariant, pinned: Bool) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-cmux-mobile-welcome-hero"), i + 1 < arguments.count {
            let value = arguments[i + 1].lowercased()
            if let n = Int(value), let v = WelcomeHeroVariant(rawValue: n - 1) { return (v, true) }
            if let v = allCases.first(where: { $0.name.lowercased() == value }) { return (v, true) }
        }
        let stored = UserDefaults.standard.integer(forKey: storeKey)
        return (WelcomeHeroVariant(rawValue: stored) ?? .now, false)
        #else
        return (.now, true)
        #endif
    }

    static let storeKey = "cmuxMobile.prototype.welcomeHero"
}

/// Shared easing for the heroes' entrances: `ease-out`, under 0.5 s, transform
/// and opacity only. `t` is seconds since the hero appeared (`.infinity` settled).
private enum HeroEntrance {
    /// Opacity and rise of the `index`th piece, `step` apart, starting at `start`.
    static func piece(_ t: Double, index: Int, start: Double = 0.1, step: Double = 0.07, length: Double = 0.4) -> Double {
        IntroEase.outQuint(IntroEase.seg(t, start + Double(index) * step, start + Double(index) * step + length))
    }
}

private extension View {
    /// Fades in and rises `rise` points as `p` goes 0 → 1.
    func heroPiece(_ p: Double, rise: CGFloat = 10) -> some View {
        opacity(p).offset(y: rise * CGFloat(1 - p))
    }
}

// MARK: Terminal

/// A Mac's agent session, drawn as a small dark window: the product itself.
struct WelcomeHeroTerminal: View {
    var t: Double
    var showsArt: Bool
    @ScaledMetric(relativeTo: .footnote) private var mono: CGFloat = 13

    private struct Line: Identifiable {
        let id: Int
        let glyph: String
        let tint: Color
        let text: String
        let dim: Bool
    }

    private static let blue = Color(red: 0.36, green: 0.62, blue: 1.0)
    private static let green = Color(red: 0.25, green: 0.84, blue: 0.43)
    private static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)

    private let lines: [Line] = [
        Line(id: 0, glyph: "❯", tint: blue, text: "fix the flaky login test", dim: false),
        Line(id: 1, glyph: "●", tint: .white.opacity(0.55), text: "Reading auth/session.ts", dim: true),
        Line(id: 2, glyph: "●", tint: .white.opacity(0.55), text: "Edited 2 files  +18 −4", dim: true),
        Line(id: 3, glyph: "✓", tint: green, text: "42 tests passed", dim: false),
        Line(id: 4, glyph: "?", tint: amber, text: "Open a pull request?", dim: false),
    ]

    var body: some View {
        VStack(spacing: 28) {
            if showsArt {
                window
                    .heroPiece(HeroEntrance.piece(t, index: 0, start: 0.05, length: 0.45), rise: 14)
            }
            VStack(spacing: 10) {
                Text("Your agents, on your phone.")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.colors.label)
                    .accessibilityAddTraits(.isHeader)
                Text("Watch them work on your Mac, answer when they ask, and ship from anywhere.")
                    .font(.body)
                    .foregroundStyle(theme.colors.label2)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, theme.metrics.sideMargin + 8)
            .heroPiece(HeroEntrance.piece(t, index: 0, start: 0.15))
        }
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 9, height: 9)
                }
                Spacer()
                Text(verbatim: "MacBook Pro — claude")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Color.clear.frame(width: 39, height: 9)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: line.glyph).foregroundStyle(line.tint)
                        Text(verbatim: line.text).foregroundStyle(.white.opacity(line.dim ? 0.55 : 0.92))
                            .lineLimit(1)
                    }
                    .font(.system(size: min(mono, 16), weight: .regular, design: .monospaced))
                    .opacity(IntroEase.out(IntroEase.seg(t, 0.35 + Double(line.id) * 0.16, 0.5 + Double(line.id) * 0.16)))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .frame(maxWidth: 340)
        .padding(.horizontal, theme.metrics.sideMargin + 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("An agent on your Mac fixed a test and asks to open a pull request."))
    }
}

// MARK: Statement

/// Large left-aligned type, no picture: confident and quiet.
struct WelcomeHeroStatement: View {
    var t: Double
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your Macs.")
                    .foregroundStyle(theme.colors.label)
                    .heroPiece(HeroEntrance.piece(t, index: 0))
                Text("In your pocket.")
                    .foregroundStyle(theme.colors.label3)
                    .heroPiece(HeroEntrance.piece(t, index: 1))
            }
            .font(.system(size: min(size, 72), weight: .bold))
            .tracking(-0.8)
            .lineSpacing(-2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Your Macs. In your pocket."))
            .accessibilityAddTraits(.isHeader)
            Text("Run, watch and steer the coding agents on your Macs from your iPhone.")
                .font(.title3)
                .foregroundStyle(theme.colors.label2)
                .heroPiece(HeroEntrance.piece(t, index: 2))
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 440, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.metrics.sideMargin + 4)
    }
}

// MARK: Mark

/// The app icon's chevron, large in a soft glow, the wordmark and one line.
/// `slot` is where the launch mark lands (it glides here from the launch screen).
struct WelcomeHeroMark<Slot: View>: View {
    var t: Double
    var showsArt: Bool
    @ViewBuilder var slot: () -> Slot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let glow = HeroEntrance.piece(t, index: 0, start: 0.2, length: 0.6)
        VStack(spacing: 22) {
            slot()
                .background {
                    if showsArt {
                        ZStack {
                            Circle()
                                .fill(RadialGradient(
                                    colors: [Color(red: 0.25, green: 0.55, blue: 1).opacity(colorScheme == .dark ? 0.45 : 0.22), .clear],
                                    center: .center, startRadius: 0, endRadius: 130))
                                .frame(width: 260, height: 260)
                            ForEach(0..<2) { ring in
                                Circle()
                                    .strokeBorder(theme.colors.label.color.opacity(colorScheme == .dark ? 0.10 : 0.07), lineWidth: 1)
                                    .frame(width: 150 + CGFloat(ring) * 80, height: 150 + CGFloat(ring) * 80)
                            }
                        }
                        .opacity(glow)
                        .scaleEffect(0.85 + 0.15 * glow)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, showsArt ? 40 : 0)
            VStack(spacing: 8) {
                Text(verbatim: "cmux")
                    .font(.system(.largeTitle, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(theme.colors.label)
                    .accessibilityAddTraits(.isHeader)
                Text("Your Macs, in your pocket.")
                    .font(.title3)
                    .foregroundStyle(theme.colors.label2)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, theme.metrics.sideMargin)
            .heroPiece(HeroEntrance.piece(t, index: 0, start: 0.3))
        }
    }
}

// MARK: Feed

/// What reaches the phone: three agent notifications, stacked like the Lock Screen.
struct WelcomeHeroFeed: View {
    var t: Double
    var showsArt: Bool
    @Environment(\.colorScheme) private var colorScheme

    private struct Note: Identifiable {
        let id: Int
        let title: String
        let time: String
        let body: String
        let symbol: String
        let tint: Color
    }

    private let notes: [Note] = [
        Note(id: 0, title: "Claude · api-server", time: "now", body: "Needs you: run the database migration?", symbol: "hand.raised.fill", tint: Color(red: 1, green: 0.62, blue: 0.04)),
        Note(id: 1, title: "Codex · ios-app", time: "2m ago", body: "Done. 42 tests pass, 3 files changed.", symbol: "checkmark", tint: Color(red: 0.2, green: 0.78, blue: 0.35)),
        Note(id: 2, title: "MacBook Pro", time: "9m ago", body: "Build finished in 2m 14s.", symbol: "laptopcomputer", tint: Color(red: 0.36, green: 0.62, blue: 1)),
    ]

    var body: some View {
        VStack(spacing: 28) {
            if showsArt {
                VStack(spacing: 8) {
                    ForEach(notes) { note in
                        card(note)
                            .heroPiece(HeroEntrance.piece(t, index: note.id, start: 0.1, step: 0.08), rise: -12)
                    }
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, theme.metrics.sideMargin)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Notifications from your agents: one needs you, one is done, a build finished."))
            }
            VStack(spacing: 10) {
                Text("Know the moment an agent needs you.")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.colors.label)
                    .accessibilityAddTraits(.isHeader)
                Text("Answer from your phone. Your Macs keep working.")
                    .font(.body)
                    .foregroundStyle(theme.colors.label2)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, theme.metrics.sideMargin + 8)
            .heroPiece(HeroEntrance.piece(t, index: 3, start: 0.1, step: 0.08))
        }
    }

    private func card(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black)
                CmuxLogoMark(chevronHeight: 15)
            }
            .frame(width: 36, height: 36)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: note.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(note.tint, in: Circle())
                    .overlay { Circle().strokeBorder(theme.colors.surface.color, lineWidth: 1.5) }
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: note.title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.colors.label)
                    Spacer(minLength: 6)
                    Text(verbatim: note.time).font(.footnote).foregroundStyle(theme.colors.label2)
                }
                Text(verbatim: note.body).font(.subheadline).foregroundStyle(theme.colors.label)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(theme.colors.surface.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(theme.colors.label.color.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.08), radius: 14, y: 4)
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
            ForEach(WelcomeHeroVariant.allCases) { variant in
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

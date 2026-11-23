public import CmuxTheme
import Foundation

/// `appearance.twoTone`: a toggle under any chrome style and any theme. The chrome (the sidebar and the tab bar) takes
/// tone A, the content panes (terminal, agent pane, New Tab page, Home) take tone B. Leo, 2026-11-19: "the two-tone ...
/// that's just one of the toggles you can have ... what would actually look good and not eyesore-ish".
///
/// The colors and the pairing table are Rust's (cmux-config `theme_file::two_tone`); this is its mirror, checked
/// against the Rust output (`TwoToneTests` has Rust write its fixture at test time). Every tone keeps the theme's
/// text at 4.5:1 and the accent at 3:1 on both tones, moving only OKLCH lightness. An explicit
/// `appearance.surfaces.<surface>.color` still wins (``SurfaceBackgrounds``).
///
/// - `off` (the default): nothing changes.
/// - `auto`: tone A from the theme: its background a step lighter in dark, darker in light, turned toward the
///   accent's hue; the content keeps the theme's background.
/// - A pairing: a curated chrome, content and accent, with a light and a dark variant.
public nonisolated enum TwoTone: String, Sendable, CaseIterable, Codable, Hashable {
    case off
    case auto
    case inkSakura
    case charcoalRose
    case inkMagenta
    case creamForest
    case navySand
    case boneOxblood
    case slateMatcha
    case plumAmber

    /// Text on a tone (WCAG 2 AA).
    public static let textMinimum = 4.5
    /// The accent on a tone (WCAG 2 non-text).
    public static let markMinimum = 3.0
    /// `auto`: tone A's OKLCH lightness step from the background.
    static let autoLightnessStep = 0.045
    /// `auto`, dark: tone A's least OKLCH lightness, so a black background still gets a tone apart from it.
    static let autoDarkFloor = 0.18
    /// `auto`: the share tone A turns from the background toward the accent in OKLab's a/b plane.
    static let autoAccentShare = 0.12
    /// `auto`: an accent with less OKLCH chroma is neutral and adds no tint.
    static let autoHuedChroma = 0.04
    /// `auto`: tone A's most chroma, unless the background has more of its own.
    static let autoMaxChroma = 0.02
    /// `auto`: a tone nearer the background than this (the text pushed it back) steps the other way.
    static let autoLeastStep = 0.02

    /// One variant of a pairing, as `0xRRGGBB`.
    public struct Variant: Sendable, Hashable {
        public let chrome: UInt32
        public let content: UInt32
        public let accent: UInt32
    }

    /// What a two-tone paints.
    public struct Tones: Sendable, Hashable {
        /// Tone A: the sidebar and the tab bar.
        public let chrome: ThemeRGB
        /// Tone B: the content panes; nil keeps the theme's own (`auto`).
        public let content: ThemeRGB?
        /// The accent, standing out on both tones.
        public let accent: ThemeRGB
    }

    /// The pairing's dark and light variants (Rust `PAIRINGS`); nil for `off` and `auto`.
    public var variants: (dark: Variant, light: Variant)? {
        func v(_ chrome: UInt32, _ content: UInt32, _ accent: UInt32) -> Variant {
            Variant(chrome: chrome, content: content, accent: accent)
        }
        return switch self {
        case .off, .auto: nil
        case .inkSakura: (v(0x1E1A24, 0x131118, 0xF4A6C0), v(0xF5E3EA, 0xFCF8F6, 0xC24D7C))
        case .charcoalRose: (v(0x161616, 0x202020, 0xEE5396), v(0xEDEDED, 0xFAFAFA, 0xD02670))
        case .inkMagenta: (v(0x082451, 0x0D1526, 0xD32D6B), v(0xD9E2F0, 0xF7F9FC, 0xB0245A))
        case .creamForest: (v(0x1B2E24, 0x151A16, 0xE3D6B0), v(0xEFE8D6, 0xFBF8F0, 0x2E6B4E))
        case .navySand: (v(0x14213D, 0x11151D, 0xDDBE91), v(0xECE1CE, 0xFAF7F1, 0x1F3B6E))
        case .boneOxblood: (v(0x2B1518, 0x171313, 0xE8DDCB), v(0xE8E0D2, 0xF9F6F0, 0x7D2433))
        case .slateMatcha: (v(0x1F2622, 0x151917, 0xA9C98A), v(0xE4ECDB, 0xFAFBF7, 0x4D6B2C))
        case .plumAmber: (v(0x261B30, 0x17131C, 0xF0B45C), v(0xEEE4F3, 0xFCFAFD, 0x985A10))
        }
    }

    /// Whether this value paints the content panes (a pairing; `auto` keeps the theme's).
    public var paintsContent: Bool { variants != nil }

    /// The tones this value gives a theme; nil for `off`.
    /// - Parameters:
    ///   - background: The theme's background.
    ///   - foreground: The theme's primary text, kept readable on both tones.
    ///   - accent: The theme's accent.
    ///   - dark: Whether the theme is dark: it picks a pairing's variant.
    public func tones(background: ThemeRGB, foreground: ThemeRGB, accent: ThemeRGB, dark: Bool) -> Tones? {
        func readable(_ tone: ThemeRGB) -> ThemeRGB {
            tone.fitted(contrast: [(foreground, Self.textMinimum)], lighter: !dark)
        }
        func mark(_ color: ThemeRGB, _ chrome: ThemeRGB, _ content: ThemeRGB) -> ThemeRGB {
            color.fitted(contrast: [(chrome, Self.markMinimum), (content, Self.markMinimum)], lighter: dark)
        }
        switch self {
        case .off:
            return nil
        case .auto:
            let ground = background.oklch, tint = accent.oklch
            // A ground with a tint of its own (Solarized's cream) keeps it: the accent tints only a neutral one.
            let neutral = max(1 - ground.chroma / Self.autoMaxChroma, 0)
            let share = tint.chroma >= Self.autoHuedChroma ? Self.autoAccentShare * neutral : 0
            func plane(_ chroma: Double, _ hue: Double) -> (Double, Double) {
                let radians = hue * (Double.pi / 180)
                return (chroma * cos(radians), chroma * sin(radians))
            }
            let (ga, gb) = plane(ground.chroma, ground.hue), (aa, ab) = plane(tint.chroma, tint.hue)
            let a = ga + (aa - ga) * share, b = gb + (ab - gb) * share
            let chroma = min(hypot(a, b), max(ground.chroma, Self.autoMaxChroma))
            var hue = atan2(b, a) * (180 / Double.pi)
            hue = hue.truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            func at(_ lightness: Double) -> ThemeRGB {
                readable(ThemeRGB(oklchLightness: min(max(lightness, 0), 1), chroma: chroma, hue: hue))
            }
            let toward = dark ? max(ground.lightness + Self.autoLightnessStep, Self.autoDarkFloor) : ground.lightness - Self.autoLightnessStep
            let away = dark ? ground.lightness - Self.autoLightnessStep : ground.lightness + Self.autoLightnessStep
            func apart(_ tone: ThemeRGB) -> Double { abs(tone.oklch.lightness - ground.lightness) }
            var chrome = at(toward)
            if apart(chrome) < Self.autoLeastStep {
                let other = at(away)
                if apart(other) > apart(chrome) { chrome = other }
            }
            return Tones(chrome: chrome, content: nil, accent: mark(accent, chrome, background))
        default:
            guard let variants else { return nil }
            let variant = dark ? variants.dark : variants.light
            let chrome = readable(ThemeRGB(hex: variant.chrome)), content = readable(ThemeRGB(hex: variant.content))
            return Tones(chrome: chrome, content: content, accent: mark(ThemeRGB(hex: variant.accent), chrome, content))
        }
    }

    /// The tone `kind` takes under this value for `tokens`, or nil when it keeps its own: the sidebar and the tab bar
    /// take tone A; the terminal, the agent pane, the New Tab page and Home take tone B.
    public func color(for kind: SurfaceKind, tokens: ThemeTokens) -> ThemeRGB? {
        guard self != .off else { return nil }
        let chrome: Bool
        switch kind {
        case .sidebar, .tabBar: chrome = true
        case .terminal, .agentPane, .newTabPage, .home: chrome = false
        default: return nil
        }
        if !chrome, !paintsContent { return nil }
        guard let tones = tones(background: tokens.surfaceBackground.withAlpha(1), foreground: tokens.textPrimary.withAlpha(1),
                                accent: tokens.accent.withAlpha(1), dark: tokens.isDark) else { return nil }
        return chrome ? tones.chrome : tones.content
    }
}

public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// The omnibar's ink (https://github.com/manaflow-ai/cmux/issues/50986): one set of text and icon colors
/// for everything drawn on the bar (the URL's host and path, the typed text, the placeholder and caret, the
/// site-info chip, the bookmark star in both states, the profile and machine badges), fitted to every
/// ground the bar can show: its rest and hover fill, its glass, a see-through window over a black or a white
/// desktop, and the opaque card while editing. Each ink keeps the theme's own color when it reads at
/// ``ThemeTokens/minimumTextContrast`` on all of them, and moves toward black or white until it does
/// otherwise.
///
/// Before, each element took a fixed theme tone (`textPrimary`, `textSecondary`, the primary at 83%) with no
/// look at the bar it sat on: the secondary tone, muted to 4.5:1 over the bare window, fell under it over the
/// bar's lift, the glass or a see-through window, and the star drew the secondary tone until it was clicked
/// and the primary after (a hollow gray star turning white). One ink per bar, not per state: hover, focus
/// and bookmarking change no element's color.
public nonisolated struct OmnibarInk: Hashable, Sendable {
    /// The host, typed text, plain text, "Not secure" label and caret.
    public let primary: ThemeRGB
    /// The path after the host and the placeholder.
    public let secondary: ThemeRGB
    /// The site-info glyph, the star (hollow and filled alike) and the badges' text and glyphs.
    public let icon: ThemeRGB
    /// The opaque grounds the inks were fitted to.
    public let grounds: [ThemeRGB]

    /// Inks for `grounds` (each composited to opaque), from the theme's `text` and `secondaryText`.
    /// The icon starts from Chrome's results-icon tone, the primary at 83%.
    public init(text: ThemeRGB, secondaryText: ThemeRGB, grounds: [ThemeRGB],
                minimum: Double = ThemeTokens.minimumTextContrast) {
        let grounds = grounds.isEmpty ? [ThemeRGB.black] : grounds.map { $0.withAlpha(1) }
        self.grounds = grounds
        let primary = Self.readable(text, over: grounds, minimum: minimum)
        self.primary = primary
        self.secondary = Self.readable(secondaryText, over: grounds, minimum: minimum, fallback: primary)
        self.icon = Self.readable(text.withAlpha(text.alpha * 0.83), over: grounds, minimum: minimum, fallback: primary)
    }

    /// The icon ink for a mark that sits on the bar bare and on each of `plates` laid over it (a badge's plate, the
    /// star's and the chip's hover and press plates): the icon ink when it reads on all of them, else the primary, else a
    /// step toward black or white. One color, so a hover or a press changes the plate, never the mark.
    public func icon(on plates: [ThemeRGB], bare: Bool = true, minimum: Double = ThemeTokens.minimumTextContrast) -> ThemeRGB {
        var under = bare ? grounds : []
        for plate in plates { under += grounds.map { plate.composited(over: $0) } }
        guard !under.isEmpty else { return icon }
        return Self.readable(icon, over: under, minimum: minimum, fallback: primary)
    }

    /// The least contrast `ink` keeps over `grounds` (composited, for a translucent ink).
    public static func worstContrast(_ ink: ThemeRGB, over grounds: [ThemeRGB]) -> Double {
        grounds.map { ink.composited(over: $0).contrast(with: $0.withAlpha(1)) }.min() ?? 21
    }

    /// `preferred` when it reads on every ground; else `fallback` (the primary) when it does; else the
    /// preferred color moved toward black or white, whichever reads better, the least step that reaches
    /// `minimum`; else the better pole (no single ink reaches it on grounds both light and dark).
    static func readable(_ preferred: ThemeRGB, over grounds: [ThemeRGB], minimum: Double, fallback: ThemeRGB? = nil) -> ThemeRGB {
        if worstContrast(preferred, over: grounds) >= minimum { return preferred }
        if let fallback, worstContrast(fallback, over: grounds) >= minimum { return fallback }
        let poles = [ThemeRGB.white, ThemeRGB.black]
        let pole = poles.max { worstContrast($0, over: grounds) < worstContrast($1, over: grounds) } ?? .white
        // Opaque on the first ground, so the step is a color a person sees, not a translucent one.
        let start = preferred.composited(over: grounds[0])
        for percent in stride(from: 5, through: 100, by: 5) {
            let candidate = start.mixed(toward: pole, Double(percent) / 100)
            if worstContrast(candidate, over: grounds) >= minimum { return candidate }
        }
        return pole
    }
}

public extension AddressBarSurface {
    /// What draws under the bar's ink at rest (`OmnibarGlassLook.Material`).
    enum Backing: Hashable, Sendable {
        /// The flat tonal fill at the look's `coverage`.
        case flat(coverage: Double)
        /// No fill: the toolbar shows through; `hover` is the see-through hover fill.
        case clear(hover: ThemeRGB)
        /// Glass: the material in this theme's light or dark look, under each of `tints` (the rest tint and the
        /// editing one, stronger; nil: none) and the bar's `hover` lift.
        case glass(tints: [ThemeRGB?], hover: ThemeRGB)
    }

    /// The desktop extremes behind a see-through window (`worstContrast`); one ground in an opaque window.
    var desktops: [ThemeRGB] { windowOpacity < 1 ? [.black, .white] : [.black] }

    /// The toolbar behind the bar over each desktop: the theme background at the window's opacity.
    var toolbarGrounds: [ThemeRGB] { desktops.map { background.withAlpha(windowOpacity).composited(over: $0) } }

    /// Liquid Glass's own frost before the tint: lighter than what is behind it in a light look, darker in a
    /// dark one. Measured over the cmux toolbar on macOS 26 (glass regular, no tint): about a third of the way
    /// toward white (light) or black (dark).
    static func glassFrost(isDark: Bool) -> (toward: ThemeRGB, step: Double) {
        isDark ? (ThemeRGB.black, 0.30) : (ThemeRGB.white, 0.35)
    }

    /// Every opaque ground the bar can show its ink on with `backing`: rest and hover, over each desktop,
    /// and the opaque card the bar becomes while editing.
    func inkGrounds(_ backing: Backing) -> [ThemeRGB] {
        var grounds: [ThemeRGB] = [card]
        switch backing {
        case .flat(let coverage):
            let coverage = resolvedCoverage(coverage)
            for state in State.allCases {
                let fill = layered(step: readableStep(state), coverage: coverage)
                grounds += toolbarGrounds.map { fill.composited(over: $0) }
            }
        case .clear(let hover):
            grounds += toolbarGrounds
            grounds += toolbarGrounds.map { hover.composited(over: $0) }
        case .glass(let tints, let hover):
            let frost = Self.glassFrost(isDark: isDark)
            for ground in toolbarGrounds {
                let frosted = ground.mixed(toward: frost.toward, frost.step)
                for tint in tints.isEmpty ? [nil] : tints {
                    let glass = tint.map { $0.composited(over: frosted) } ?? frosted
                    grounds += [glass, hover.composited(over: glass)]
                }
            }
        }
        return grounds
    }

    /// The bar's ink with `backing`.
    func ink(_ backing: Backing, secondaryText: ThemeRGB) -> OmnibarInk {
        OmnibarInk(text: text, secondaryText: secondaryText, grounds: inkGrounds(backing))
    }
}

public extension Palette {
    /// The omnibar's ink in the active theme scope and its window (`addressBar`): over the glass under each of
    /// `glassTints` when `glass`, over nothing (the toolbar) when `transparent`, else over the flat fill at `coverage`.
    @MainActor static func omnibarInk(glass: Bool, transparent: Bool, glassTints: [NSColor?], coverage: Double) -> OmnibarInk {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let backing: AddressBarSurface.Backing = if glass {
            .glass(tints: glassTints.map { $0.flatMap(ThemeRGB.init(srgb:)) }, hover: tokens.hoverFill)
        } else if transparent {
            .clear(hover: tokens.hoverFill)
        } else {
            .flat(coverage: coverage)
        }
        return addressBar.ink(backing, secondaryText: tokens.textSecondary)
    }
}

public extension OmnibarInk {
    /// ``primary`` for AppKit.
    nonisolated var primaryColor: NSColor { primary.nsColor }
    /// ``secondary`` for AppKit.
    nonisolated var secondaryColor: NSColor { secondary.nsColor }
    /// ``icon`` for AppKit.
    nonisolated var iconColor: NSColor { icon.nsColor }
    /// Whether `color` reads on every ground at the text minimum.
    nonisolated func reads(_ color: NSColor) -> Bool {
        ThemeRGB(srgb: color).map { Self.worstContrast($0, over: grounds) >= ThemeTokens.minimumTextContrast } ?? false
    }
    /// ``icon(on:bare:minimum:)`` for plates of these colors (a color with no sRGB form is left out). `bare`: the
    /// mark also shows with no plate (the star and chip at rest; a badge always has its plate).
    nonisolated func iconColor(on plates: [NSColor], bare: Bool = true) -> NSColor {
        icon(on: plates.compactMap(ThemeRGB.init(srgb:)), bare: bare).nsColor
    }
}

extension ThemeRGB {
    /// `color` in sRGB; nil for a color with no sRGB form (a pattern).
    nonisolated init?(srgb color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }
}

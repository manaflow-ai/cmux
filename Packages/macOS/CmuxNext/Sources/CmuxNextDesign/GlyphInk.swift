public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// One foreground for every glyph on a surface (cx-qno.22, Lawrence
/// 2026-10-11: the group header's more dots read paler than its chevron).
/// A header's name, chevron, more and add buttons, pin and icon all take this
/// one color, derived from the surface under them, so no glyph is paler than
/// another and each one keeps WCAG text contrast (4.5:1, which also covers
/// the 3:1 icons need) on the surface and on the hover and pressed fills its
/// buttons add. Hover and press show as the button's fill, never as a
/// different glyph color. The ground is opaque: over a see-through window
/// the wallpaper is not known here, the same limit every text token has.
/// A glyph with its own chosen color (an icon tint, an emoji) is the
/// person's content and keeps that color.
extension ThemeTokens {
    /// The ink for glyphs on `fill` (nil: no fill) painted over `base`.
    ///
    /// The theme's primary text color when it reaches 4.5:1 on every state
    /// surface; else near-black or white, whichever reads on a colored fill;
    /// else the best of them pushed to the minimum.
    ///
    /// - Parameters:
    ///   - fill: A fill under the glyphs (a translucent fill composites over `base`).
    ///   - base: The surface under the fill; nil is the sidebar background.
    /// - Returns: An opaque ink.
    nonisolated public func glyphInk(over fill: ThemeRGB? = nil, base: ThemeRGB? = nil) -> ThemeRGB {
        let ground = (base ?? sidebarBackground).withAlpha(1)
        let surface = fill?.composited(over: ground) ?? ground
        let states = [surface, hoverFill.composited(over: surface), pressedFill.composited(over: surface)]
        func worst(_ ink: ThemeRGB) -> Double { states.map { ink.contrast(with: $0) }.min() ?? 1 }
        let candidates = [textPrimary.composited(over: surface), ThemeRGB(hex: 0x1F1F1F), .white, .black]
        if let fit = candidates.first(where: { worst($0) >= Self.minimumTextContrast }) { return fit }
        let best = candidates.max { worst($0) < worst($1) } ?? .white
        let hardest = states.min { best.contrast(with: $0) < best.contrast(with: $1) } ?? surface
        return Self.readable(best, over: hardest, minimum: Self.minimumTextContrast)
    }
}

/// The inks a colored chip may take (`ThemeTokens.chip`).
public nonisolated enum ChipInks: Sendable {
    /// The theme's primary text when it reads, else near-black or white.
    case theme
    /// Near-black or white, whichever has more contrast on the chip's color.
    case onColor
}

extension ThemeTokens {
    /// A colored chip (the solid group header, cx-qno.22) and its one ink:
    /// the ink is chosen once on `color`, then the chip color is moved away
    /// from the ink until the ink holds 4.5:1 on the chip, on its hover and
    /// drop steps, and on its buttons' hover and pressed fills over those.
    /// The ink never changes with hover, so it cannot flip while a fill fades.
    ///
    /// - Parameters:
    ///   - color: The chip's color as chosen (opaque).
    ///   - inks: Which inks the chip may take.
    /// - Returns: The chip color to paint at rest and its ink.
    nonisolated public func chip(_ color: ThemeRGB, inks: ChipInks = .theme) -> (fill: ThemeRGB, ink: ThemeRGB) {
        let poles = [ThemeRGB(hex: 0x1F1F1F), .white].sorted { $0.contrast(with: color.withAlpha(1)) > $1.contrast(with: color.withAlpha(1)) }
        let candidates = switch inks {
        case .theme: [textPrimary.composited(over: color.withAlpha(1)), ThemeRGB(hex: 0x1F1F1F), .white]
        case .onColor: poles
        }
        func states(_ bar: ThemeRGB) -> [ThemeRGB] {
            let hovered = hoverFill.composited(over: bar)
            let dropped = pressedFill.composited(over: bar)
            return [bar, hovered, dropped] + [bar, hovered, dropped].flatMap {
                [hoverFill.composited(over: $0), pressedFill.composited(over: $0)]
            }
        }
        func worst(_ ink: ThemeRGB, _ bar: ThemeRGB) -> Double { states(bar).map { ink.contrast(with: $0) }.min() ?? 1 }
        let bar = color.withAlpha(1)
        let ink = candidates.first { worst($0, bar) >= Self.minimumTextContrast }
            ?? candidates.max { worst($0, bar) < worst($1, bar) } ?? .white
        let pole: ThemeRGB = ink.relativeLuminance > 0.5 ? .black : .white
        var fill = bar
        var step = 0.0
        while worst(ink, fill) < Self.minimumTextContrast, step < 1 {
            step += 0.02
            fill = bar.mixed(toward: pole, step)
        }
        return (fill, ink)
    }
}

extension Palette {

    /// ``CmuxTheme/ThemeTokens/glyphInk(over:base:)`` in the active theme
    /// scope for a sidebar glyph, for a fill named by its token (nil: no
    /// fill). The ground is the sidebar as it paints: the person's sidebar
    /// background (`appearance.surfaces.sidebar`) when set, else the theme's.
    @MainActor public static func glyphInk(over fill: KeyPath<ThemeTokens, ThemeRGB>? = nil) -> NSColor {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let ground = ThemeScope.app.surfaceBackgrounds.opaqueFill(for: .sidebar, tokens: tokens,
                                                                  base: tokens.sidebarBackground.withAlpha(1))
        return tokens.glyphInk(over: fill.map { tokens[keyPath: $0] }, base: ground).nsColor
    }
}

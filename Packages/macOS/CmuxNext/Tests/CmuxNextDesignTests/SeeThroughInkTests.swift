@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Sidebar sweep 2026-10-21: glass at Opacity 0.6 in light mode over a dark desktop left the
/// sidebar's secondary glyphs (App Store, the footer's chevron and search) and the Home page's
/// body text faint. The inks held their contrast only over the opaque theme background. The tint
/// stays the Opacity asked for (#22566); the secondary and tertiary inks hold their minimums over
/// the window's tint on the worst desktop for the theme (black behind a light theme, white behind
/// a dark one), as far as the primary ink itself reaches there.
@Suite struct SeeThroughInkTests {
    static let light = ThemeInput(background: ThemeRGB(hex: 0xFEFFFF), foreground: ThemeRGB(hex: 0x000000))
    static let dark = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xFFFFFF))

    static func tokens(_ theme: ThemeInput, opacity: Double, blur: Int = -1) -> ThemeTokens {
        var input = theme
        input.backgroundOpacity = opacity
        input.backgroundBlur = blur
        return ThemeTokens.derive(from: input)
    }

    /// The surfaces text sits on in a see-through window over the theme's worst desktop: the
    /// tint alone, and the pressed and selected fills over it.
    static func surfaces(_ tokens: ThemeTokens) -> [ThemeRGB] {
        let desktop: ThemeRGB = tokens.isDark ? .white : .black
        let tint = tokens.windowBackground.composited(over: desktop)
        return [tint] + [tokens.pressedFill, tokens.selectionFill].map { $0.composited(over: tint) }
    }

    @Test func lightGlassOverADarkDesktopKeepsSecondaryTextAtAA() {
        let tokens = Self.tokens(Self.light, opacity: 0.6)
        for surface in Self.surfaces(tokens) {
            #expect(tokens.textSecondary.contrast(with: surface) >= ThemeTokens.minimumTextContrast,
                    "secondary \(tokens.textSecondary) on \(surface)")
            #expect(tokens.textTertiary.contrast(with: surface) >= ThemeTokens.minimumMarkContrast,
                    "tertiary \(tokens.textTertiary) on \(surface)")
        }
    }

    @Test(arguments: [0.3, 0.5, 0.6, 0.75, 0.9])
    func secondaryInksHoldTheirMinimumsAsFarAsThePrimaryReaches(opacity: Double) {
        for theme in [Self.light, Self.dark] {
            let tokens = Self.tokens(theme, opacity: opacity)
            for surface in Self.surfaces(tokens) {
                let reach = tokens.textPrimary.contrast(with: surface)
                #expect(tokens.textSecondary.contrast(with: surface) >= min(ThemeTokens.minimumTextContrast, reach) - 1e-9)
                #expect(tokens.textTertiary.contrast(with: surface) >= min(ThemeTokens.minimumMarkContrast, reach) - 1e-9)
            }
        }
    }

    /// An opaque window keeps the inks it had: the floor is only for see-through windows.
    @Test func anOpaqueWindowKeepsItsInks() {
        let opaque = Self.tokens(Self.light, opacity: 1, blur: 0)
        let glassAtOne = Self.tokens(Self.light, opacity: 1)
        #expect(opaque.textSecondary == glassAtOne.textSecondary)
        #expect(opaque.textSecondary.contrast(with: ThemeRGB(hex: 0xFEFFFF)) < 7)
    }
}

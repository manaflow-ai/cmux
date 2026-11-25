@testable import CmuxNextDesign
import CmuxTheme
import Testing

/// A grouped form's rows (the Chief profile's groups, ``Palette/groupFill``) keep the card's text readable:
/// primary and secondary text reach 4.5:1 on a group over the popup surface, in light, dark, low-contrast
/// and colored themes, and a group still stands apart from the surface where the theme allows it.
@MainActor @Suite struct GroupFillContrastTests {
    nonisolated static let themes: [(String, ThemeInput)] = [
        ("dark", ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6))),
        ("light", ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F))),
        ("solarized dark", ThemeInput(background: ThemeRGB(hex: 0x002B36), foreground: ThemeRGB(hex: 0x839496))),
        ("solarized light", ThemeInput(background: ThemeRGB(hex: 0xFDF6E3), foreground: ThemeRGB(hex: 0x657B83))),
        ("low-contrast grey", ThemeInput(background: ThemeRGB(hex: 0x3A3A3A), foreground: ThemeRGB(hex: 0xA8A8A8))),
        ("hot dog stand", ThemeInput(background: ThemeRGB(hex: 0xFF0000), foreground: ThemeRGB(hex: 0xFFFF00))),
        ("nord", ThemeInput(background: ThemeRGB(hex: 0x2E3440), foreground: ThemeRGB(hex: 0xD8DEE9))),
    ]

    @Test(arguments: themes.map(\.0)) func textOnAGroupReachesFourAndAHalfToOne(_ name: String) throws {
        let input = try #require(Self.themes.first { $0.0 == name }?.1)
        let tokens = ThemeTokens.derive(from: input)
        let surface = tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)
        let group = tokens.groupFill.composited(over: surface)
        for (ink, text) in [("primary", tokens.textPrimary), ("secondary", tokens.textSecondary)] {
            // A theme whose text already misses 4.5:1 on the bare popup gets no worse on a group.
            let bare = text.composited(over: surface).contrast(with: surface)
            let contrast = text.composited(over: group).contrast(with: group)
            #expect(contrast >= min(ThemeTokens.minimumTextContrast, bare) - 0.01, "\(name): \(ink) text on a group is \(contrast):1, \(bare):1 bare")
        }
    }

    /// In the default light and dark themes a group is at least as strong as a hovered row.
    @Test func aGroupStandsApartInTheDefaultThemes() {
        for (name, input) in Self.themes.prefix(2) {
            let tokens = ThemeTokens.derive(from: input)
            #expect(tokens.groupFill.alpha >= tokens.hoverFill.alpha, "\(name): group \(tokens.groupFill.alpha), hover \(tokens.hoverFill.alpha)")
        }
    }
}

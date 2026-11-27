@testable import CmuxNextDesign
import Foundation
import Testing

/// Text over a see-through glass window reads. Clear Glass barely blurs, so the theme tint is all that stands
/// between the text and the desktop. #50499 capped the glass tint at 40% whatever the Opacity, and on
/// 2026-11-23 Leo's Clear Glass at Opacity 0.9 (Catppuccin Mocha) showed the wallpaper at full strength:
/// "I CANT READ THE TEXT". #51377 reverted it ("whatever before this recent update was, i want that").
/// Its tests checked how much backdrop shows through, never that the text still read. These check the text,
/// over the tint the window actually draws, on the worst desktop for the theme (white behind a dark theme,
/// black behind a light one), and that glass keeps the Opacity asked for.
///
/// Pattern page: cmuxterm-hq `docs/handbook/text-on-glass-below-contrast.md`.
@MainActor @Suite struct GlassTextContrastTests {
    static let themes: [(String, ThemeInput)] = [
        ("dark", ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))),
        ("light", ThemeInput(background: ThemeRGB(hex: 0xFFFCF0), foreground: ThemeRGB(hex: 0x100F0F))),
        ("catppuccin-mocha", ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4))),
        ("catppuccin-latte", ThemeInput(background: ThemeRGB(hex: 0xEFF1F5), foreground: ThemeRGB(hex: 0x4C4F69))),
        ("ghostty-default", .ghosttyDefault),
    ]

    static func tokens(_ input: ThemeInput, blur: Int, opacity: Double) -> ThemeTokens {
        var input = input
        input.backgroundBlur = blur
        input.backgroundOpacity = opacity
        return ThemeTokens.derive(from: input)
    }

    /// The text's contrast on the tint the window draws, over the worst desktop.
    static func worstContrast(_ tokens: ThemeTokens) -> Double {
        let tint = WindowBackdrop(tokens).tintOpacity
        let shown = tokens.windowBackground.withAlpha(tint).composited(over: tokens.isDark ? .white : .black)
        return tokens.textPrimary.contrast(with: shown)
    }

    /// Glass at the default Opacity 1: terminal and chrome text hold 4.5:1 over any desktop (or as much as the
    /// theme holds on its own background), and the window stays glass. The 40% cap read 1.7:1 for Mocha.
    @Test(arguments: [-1, -2], 0..<5)
    func glassAtFullOpacityKeepsTextReadable(blur: Int, theme: Int) {
        let (name, input) = Self.themes[theme]
        let tokens = Self.tokens(input, blur: blur, opacity: 1)
        let floor = min(ThemeTokens.minimumTextContrast, tokens.textPrimary.contrast(with: tokens.windowBackground.withAlpha(1)))
        #expect(Self.worstContrast(tokens) >= floor - 0.05,
                "\(name) glass \(blur) at Opacity 1: text reads \(Self.worstContrast(tokens)):1 over the worst desktop")
        #expect(!WindowBackdrop(tokens).isOpaque, "\(name) glass \(blur) at Opacity 1 turned opaque")
    }

    /// Glass below Opacity 1 draws the tint the user set, whatever the theme: no ceiling under it.
    @Test(arguments: [-1, -2], [0.5, 0.75, 0.9])
    func glassKeepsTheOpacityAskedFor(blur: Int, opacity: Double) {
        for (name, input) in Self.themes {
            let tint = WindowBackdrop(Self.tokens(input, blur: blur, opacity: opacity)).tintOpacity
            #expect(abs(tint - opacity) < 0.0001, "\(name) glass \(blur) at Opacity \(opacity) drew tint \(tint)")
        }
    }

    /// Leo's config on 2026-11-23: Clear Glass, Opacity 0.9, Catppuccin Mocha. The tint is the 0.9 he set and
    /// the text reads as it did before #50499 (8.4:1 over a white desktop; 1.7:1 under the cap).
    @Test func clearGlassAtNinetyPercentReadsAsBefore() {
        let tokens = Self.tokens(Self.themes[2].1, blur: -2, opacity: 0.9)
        #expect(WindowBackdrop(tokens).tintOpacity == 0.9)
        #expect(Self.worstContrast(tokens) >= ThemeTokens.minimumTextContrast)
    }
}

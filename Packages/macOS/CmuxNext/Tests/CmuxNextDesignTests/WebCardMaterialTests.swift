import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The find pills are one shared pill (`FindPillView` natively, `FindPill.tsx` in pages; a334,
/// 2026-10-20). The native pill is a `Glass.makeOverlayPanel` card, so it draws the
/// ``CardMaterial`` (Lawrence 2026-10-20: floating cards were "too liquid glassy"). Pages get the
/// same material: `--cmux-card-tint` (the card fill at its opacity) and `--cmux-card-rim`, so a
/// page's find pill matches the terminal's and keeps primary and secondary text at WCAG AA over
/// any backdrop, where the tooltip tint only keeps the primary text there.
@MainActor struct WebCardMaterialTests {
    private static let themes: [ThemeInput] = [
        ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F)),
        ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4)),
        ThemeInput(background: ThemeRGB(hex: 0x002B36), foreground: ThemeRGB(hex: 0x839496)),
        ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF), backgroundOpacity: 0.6),
    ]

    @Test func pagesGetTheCardMaterialOfNativeCards() throws {
        for input in Self.themes { try check(input) }
    }

    private func check(_ input: ThemeInput) throws {
        let tokens = ThemeTokens.derive(from: input)
        let variables = WebTheme(tokens, surface: .internalPage, backgrounds: .none).variables
        let card = CardMaterial(tokens, lift: ChromeTunables.opaqueOverlayLift.value,
                                minimumOpacity: ChromeTunables.cardOpacity.value)
        let tint = try #require(variables["--cmux-card-tint"], "\(input.background): pages get no card tint")
        #expect(tint == WebTheme.css(card.tint))
        let rim = try #require(variables["--cmux-card-rim"], "\(input.background): pages get no card rim")
        #expect(rim == (Borders.drawsLines ? WebTheme.css(card.rim) : "transparent"))
        for ink in [tokens.textPrimary, tokens.textSecondary] {
            #expect(TooltipSurface.worstContrast(ink: ink.withAlpha(1), tint: card.tint) >= ThemeTokens.minimumTextContrast,
                    "\(input.background): text \(ink) under 4.5:1 on the card tint")
        }
    }
}

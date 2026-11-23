import CmuxTheme
@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextDesignTokens

/// https://github.com/manaflow-ai/cmux/issues/50986: the omnibar's text and icons were the theme's fixed tones,
/// never fitted to the bar they sit on. The secondary tone (the path, the placeholder, the hollow star, the badges) is
/// muted to 4.5:1 over the bare window, so over the bar's lift, its hover, its glass or a see-through window it fell
/// under it, and the star drew that tone until a click made it the primary. In every theme cmux ships, with every
/// omnibar look (flat, transparent, glass) in an opaque and a see-through window, each ink of ``OmnibarInk`` reads at
/// 4.5:1 on every ground the bar can show, or is the best pole when no single ink can.
@MainActor @Suite struct OmnibarInkEveryThemeTests {
    /// The looks a person can pick (`browser.omnibar.glass`), with the glass tint at its default.
    static func backings(_ tokens: ThemeTokens) -> [(String, AddressBarSurface.Backing)] {
        [
            ("flat", .flat(coverage: 0)),
            ("flat-covered", .flat(coverage: 0.6)),
            ("transparent", .clear(hover: tokens.hoverFill)),
            ("glass", .glass(tints: [tokens.chromeBackground.withAlpha(tokens.chromeBackground.alpha * 0.35),
                                     tokens.chromeBackground.withAlpha(tokens.chromeBackground.alpha * 0.5)], hover: tokens.hoverFill)),
            ("glass-untinted", .glass(tints: [nil], hover: tokens.hoverFill)),
        ]
    }

    /// An ink reads, or nothing could: no pole does better on these grounds.
    static func readsOrBest(_ ink: ThemeRGB, _ grounds: [ThemeRGB]) -> Bool {
        let worst = OmnibarInk.worstContrast(ink, over: grounds)
        if worst >= ThemeTokens.minimumTextContrast - 0.005 { return true }
        let best = [ThemeRGB.white, .black].map { OmnibarInk.worstContrast($0, over: grounds) }.max() ?? 0
        return worst >= best - 0.005
    }

    @Test func everyInkReadsOnEveryGroundInEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 600)
        var failures: [String] = []
        var checked = 0
        for theme in themes {
            for windowOpacity in [1.0, 0.8] {
                let surface = AddressBarSurface(theme.tokens, windowOpacity: windowOpacity)
                for (name, backing) in Self.backings(theme.tokens) {
                    let ink = surface.ink(backing, secondaryText: theme.tokens.textSecondary)
                    let inks = [("primary", ink.primary), ("secondary", ink.secondary), ("icon", ink.icon),
                                ("badge", ink.icon(on: [theme.tokens.hoverFill], bare: false)),
                                ("hovered icon", ink.icon(on: [theme.tokens.hoverFill, theme.tokens.pressedFill]))]
                    for (role, color) in inks {
                        checked += 1
                        let plated = ink.grounds.map { theme.tokens.hoverFill.composited(over: $0) }
                        let grounds = switch role {
                        case "badge": plated
                        case "hovered icon": ink.grounds + plated + ink.grounds.map { theme.tokens.pressedFill.composited(over: $0) }
                        default: ink.grounds
                        }
                        if !Self.readsOrBest(color, grounds) {
                            failures.append(String(format: "%@ %@ window %.1f: %@ %.2f:1", theme.label, name, windowOpacity, role,
                                                   OmnibarInk.worstContrast(color, over: grounds)))
                        }
                    }
                }
            }
        }
        #expect(checked > 20000)
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures; first:\n" + failures.prefix(40).joined(separator: "\n")))
    }

    /// The bug: the theme's secondary tone, as the path, placeholder and hollow star drew it, misses 4.5:1 on the bar
    /// in many shipped themes. Guards that this suite keeps checking a real gap, not one the theme already closes.
    @Test func theThemesOwnSecondaryToneMissesOnTheBarInShippedThemes() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        let misses = themes.filter { theme in
            let surface = AddressBarSurface(theme.tokens, windowOpacity: 1)
            let grounds = surface.inkGrounds(.flat(coverage: 0))
            return OmnibarInk.worstContrast(theme.tokens.textSecondary, over: grounds) < ThemeTokens.minimumTextContrast
        }
        #expect(misses.count > 10, "only \(misses.count) themes' secondary tone misses on the bar")
    }

    /// One ink per bar: the star's hollow and filled states, and every state of the bar, share it (the hollow star drew
    /// the secondary tone and the filled one the primary).
    @Test func theInkIsTheThemesOwnWhereItReads() {
        let dark = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xF2F2F2),
                                                      backgroundOpacity: 1, backgroundBlur: 0))
        let ink = AddressBarSurface(dark, windowOpacity: 1).ink(.flat(coverage: 0), secondaryText: dark.textSecondary)
        #expect(ink.primary == dark.textPrimary.withAlpha(1))
        #expect(OmnibarInk.worstContrast(ink.icon, over: ink.grounds) >= ThemeTokens.minimumTextContrast)
    }

    /// A light glass look under a dark theme's text: the ink leaves the theme's white for black rather than vanish.
    @Test func anInkTheGroundsCannotReadTurnsTowardThePoleThatReads() {
        let grounds = [ThemeRGB(hex: 0xF0F0F0), ThemeRGB(hex: 0xE4E4E4)]
        let ink = OmnibarInk(text: ThemeRGB(hex: 0xF2F2F2), secondaryText: ThemeRGB(hex: 0xA0A0A0), grounds: grounds)
        for color in [ink.primary, ink.secondary, ink.icon] {
            #expect(OmnibarInk.worstContrast(color, over: grounds) >= ThemeTokens.minimumTextContrast)
            #expect(color.relativeLuminance < 0.2)
        }
    }
}

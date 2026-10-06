import AppKit
import CmuxHomeRender
import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// Lawrence 2026-10-05: sent bubbles use the cmux theme's accent (its ANSI
/// blue, `Palette.highlight`) with readable text on it (white or dark by
/// contrast); a theme with no accent uses MessagesLab's measured blue; a
/// user-chosen accent wins.
@MainActor @Suite(.serialized) struct HomeAccentTests {
    static let mocha = ThemeInput(
        background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4),
        palette: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                  0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8].map { ThemeRGB(hex: $0) })
    static let noPalette = ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4))

    struct Probe {
        let palette: HomePalette
        let highlight: NSColor
        let messagesBlue: Bool
    }

    private func resolve(_ input: ThemeInput, accentOverride: NSColor? = nil) -> Probe {
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        return scope.perform {
            Probe(palette: HomeThemePalette.resolveInScope(active: true, accentOverride: accentOverride), highlight: Palette.highlight,
                  messagesBlue: HomeThemePalette.usesMessagesBlueInScope(accentOverride: accentOverride))
        }
    }

    private static func close(_ a: HomeColor, _ b: NSColor) -> Bool {
        guard let s = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.red - s.redComponent) < 0.003 && abs(a.green - s.greenComponent) < 0.003 && abs(a.blue - s.blueComponent) < 0.003
    }

    /// WCAG contrast of two sRGB colours.
    private static func contrast(_ a: HomeColor, _ b: HomeColor) -> Double {
        func lin(_ c: CGFloat) -> Double { let c = Double(c); return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ c: HomeColor) -> Double { 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue) }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func sentBubblesUseTheThemesAccentWithReadableText() {
        let p = resolve(Self.mocha)
        #expect(!p.messagesBlue)
        #expect(Self.close(p.palette.caret, p.highlight), "the sent bubble is the theme's accent (Palette.highlight)")
        let white = HomeColor(red: 1, green: 1, blue: 1), black = HomeColor(red: 0, green: 0, blue: 0)
        let text = p.palette.outgoingText
        let best = max(Self.contrast(p.palette.caret, white), Self.contrast(p.palette.caret, black))
        #expect(abs(Self.contrast(p.palette.caret, text) - best) < 0.01,
                "Catppuccin's light blue takes dark text (the higher contrast), got \(text)")
    }

    @Test func aThemeWithNoAccentUsesMessagesLabsBlue() {
        let p = resolve(Self.noPalette)
        #expect(p.messagesBlue)
        #expect(Self.close(p.palette.caret, NSColor(srgbRed: 2 / 255, green: 132 / 255, blue: 254 / 255, alpha: 1)))
        #expect(p.palette.outgoingText == HomeColor(red: 1, green: 1, blue: 1), "white on Messages blue")
    }

    @Test func aChosenAccentWins() {
        let red = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let p = resolve(Self.noPalette, accentOverride: red)
        #expect(!p.messagesBlue)
        #expect(Self.close(p.palette.caret, red))
    }
}

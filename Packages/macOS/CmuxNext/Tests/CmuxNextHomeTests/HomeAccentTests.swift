import AppKit
import CmuxHomeRender
import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// Lawrence 2026-10-05 (evening, reversing the theme-accent decision of
/// the morning): sent bubbles are iMessage blue on every theme, MessagesLab's
/// measured Display P3 blue and gradient with white text; only an accent the
/// caller chooses (`accentOverride`) replaces it.
@MainActor @Suite(.serialized) struct HomeAccentTests {
    static let mocha = ThemeInput(
        background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4),
        palette: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                  0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8].map { ThemeRGB(hex: $0) })
    /// A light theme with a light (yellow) blue slot: the accent path gave dark text on it.
    static let light = ThemeInput(
        background: ThemeRGB(hex: 0xFAFAFA), foreground: ThemeRGB(hex: 0x383A42),
        palette: [0x383A42, 0xE45649, 0x50A14F, 0xC18401, 0xF0E68C, 0xA626A4, 0x0184BC, 0xA0A1A7,
                  0x4F525D, 0xE45649, 0x50A14F, 0xC18401, 0xF0E68C, 0xA626A4, 0x0184BC, 0xFFFFFF].map { ThemeRGB(hex: $0) })
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

    static let messagesBlue = NSColor(srgbRed: 2 / 255, green: 132 / 255, blue: 254 / 255, alpha: 1)
    static let white = HomeColor(red: 1, green: 1, blue: 1)

    @Test(arguments: ["mocha", "light"])
    func sentBubblesAreMessagesBlueWithWhiteTextOnEveryTheme(_ name: String) {
        let p = resolve(name == "mocha" ? Self.mocha : Self.light)
        #expect(p.messagesBlue, "the Fixture keeps MessagesLab's measured P3 blue and gradient (measuredAccent)")
        #expect(Self.close(p.palette.caret, Self.messagesBlue), "not the theme's accent \(p.highlight)")
        #expect(p.palette.outgoingText == Self.white, "white on Messages blue")
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

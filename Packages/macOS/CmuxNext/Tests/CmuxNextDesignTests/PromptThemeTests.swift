import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Foundation
import Testing

/// cmux Remote's prompts over every app (a device asking to control this Mac, an agent asking to use an app) wear
/// the app's theme through ``PromptTheme``, the file the app writes on a theme change (``PromptThemeFile``). Leo,
/// 2026-11-22: "im not sure what was up with the glass on it, and the lack of theming on it too".
@MainActor @Suite struct PromptThemeTests {
    static func tokens(_ input: ThemeInput) -> ThemeTokens { ThemeTokens.derive(from: input) }

    static var themes: [ThemeTokens] {
        var light = ThemeInput.ghosttyDefault
        light.background = ThemeRGB(hex: 0xF7F3EA)
        light.foreground = ThemeRGB(hex: 0x2B2A27)
        var tinted = ThemeInput.ghosttyDefault
        tinted.background = ThemeRGB(hex: 0x1E2B3A)
        tinted.foreground = ThemeRGB(hex: 0xD8E2EE)
        return [tokens(.ghosttyDefault), tokens(light), tokens(tinted)]
    }

    /// The veil is the app's prompt glass role at its density, so the two prompts cannot drift apart.
    @Test func theVeilIsTheAppsPromptGlass() throws {
        for isDark in [true, false] {
            #expect(abs(PromptTheme.veilAlpha(isDark: isDark) - Double(FloatingGlassStyle.prompt.look(isDark: isDark).veil.alpha)) < 0.001)
        }
        for tokens in Self.themes {
            let theme = PromptTheme(tokens: tokens)
            let veil = try #require(PromptTheme.rgb(theme.veil))
            #expect(abs(veil.red - tokens.glassTint.red) < 0.01 && abs(veil.blue - tokens.glassTint.blue) < 0.01)
            #expect(theme.isDark == tokens.isDark)
        }
    }

    /// Every ink reads on the card over the theme's window, and stays legible over the brightest and darkest page under it.
    @Test func everyInkReadsOverAnyApp() throws {
        for tokens in Self.themes {
            let theme = PromptTheme(tokens: tokens)
            let veil = try #require(PromptTheme.rgb(theme.veil))
            let own = veil.composited(over: tokens.windowBackground)
            let extremes = [veil.composited(over: .white), veil.composited(over: .black)]
            for (hex, minimum) in [(theme.text, 4.5), (theme.secondaryText, 4.5), (theme.danger, 4.5), (theme.tertiaryText, 3.0)] {
                let ink = try #require(PromptTheme.rgb(hex))
                // On the theme's own window at the full minimum; over any app's brightest or darkest page, still legible.
                #expect(ink.contrast(with: own) >= minimum - 0.05, "\(hex) on \(PromptTheme.hex(own))")
                for page in extremes { #expect(ink.contrast(with: page) >= 3.0, "\(hex) on \(PromptTheme.hex(page))") }
            }
        }
    }

    /// What the app writes, cmux Remote reads back the same; a missing or broken file leaves the system's look.
    @Test func theFileRoundTripsAndABrokenOneIsNone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-theme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("prompt-theme.json")
        #expect(PromptTheme.load(from: url) == nil)
        let theme = PromptTheme(tokens: Self.themes[2])
        try theme.write(to: url)
        #expect(PromptTheme.load(from: url) == theme)
        try Data("{\"isDark\":true}".utf8).write(to: url)
        #expect(PromptTheme.load(from: url) == nil)
        #expect(PromptTheme.rgb("#12345") == nil)
        #expect(PromptTheme.rgb(PromptTheme.hex(ThemeRGB(hex: 0x336699, alpha: 0.5)))?.blue ?? 0 > 0.59)
    }
}

import CmuxTheme
@testable import CmuxNextDesign
import Foundation
import Testing

/// The theme accent is never orange (standing rule): the default theme's accent tokens, native
/// (``ThemeTokens``, ``AppTheme``) and the CSS variables ``WebTheme`` hands pages, fall outside the
/// orange hue band in dark and light. The web side of the same rule is
/// `webviews/test/accent-never-orange.test.ts`, with the same band.
///
/// The default theme is read from its sources: the default pair's shipped theme files (Apple System
/// Colors and its Light pair; `BundledCmuxThemesTests` pins `GhosttyRuntime.defaultThemeSpec` to
/// them) and the default accent from `schemas/defaults/cmux-next.json`.
///
/// Exempt: workspace and tab group palette colors, the status colors (danger red, warning amber),
/// and themes or accents a person picks by name (Clay Orange, `appearance.accent: yellow`).
struct AccentNeverOrangeTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The default pair: `GhosttyRuntime.defaultDarkThemeName` / `defaultLightThemeName`.
    private static let defaultPair = ["Apple System Colors", "Apple System Colors Light"]

    /// Orange: HSL hue 10° to 45° inclusive, for a color whose RGB chroma (max - min channel) is at
    /// least 0.10. Apple's reds sit near 3° (systemRed #ff3b30, dark #ff453a, the default pair's
    /// ANSI red #cc372e) and yellows from 48° (systemYellow #ffcc00, dark #ffd60a, ANSI #cdac08),
    /// while oranges run from 14° (Clay Orange's #d87657) through #e8743b (20°) to systemOrange
    /// (35°, dark #ff9f0a 36.5°). Below the chroma floor a color reads as grey (the neutral default
    /// accent is the text color) and its hue is rounding noise.
    static func isOrange(_ color: ThemeRGB) -> Bool {
        let high = max(color.red, color.green, color.blue), low = min(color.red, color.green, color.blue)
        let chroma = high - low
        guard chroma >= 0.10 else { return false }
        var sector: Double
        if high == color.red {
            sector = (color.green - color.blue) / chroma
            if sector < 0 { sector += 6 }
        } else if high == color.green {
            sector = (color.blue - color.red) / chroma + 2
        } else {
            sector = (color.red - color.green) / chroma + 4
        }
        let hue = sector * 60
        return hue >= 10 && hue <= 45
    }

    /// The default accent (`setting.appearance.accent`), from the generated defaults.
    private static func defaultAccent() throws -> ThemeAccent {
        let data = try Data(contentsOf: repoRoot.appending(path: "schemas/defaults/cmux-next.json"))
        let snapshot = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defaults = try #require(snapshot["defaults"] as? [String: Any])
        let raw = try #require(defaults["setting.appearance.accent"] as? String)
        return try #require(ThemeAccent(rawValue: raw), "unknown default accent \(raw)")
    }

    /// The default theme as the app reads it: the shipped theme file's colors and the default accent.
    private static func defaultInputs() throws -> [(name: String, input: ThemeInput)] {
        let accent = try defaultAccent()
        return try defaultPair.map { name in
            let text = try String(contentsOf: repoRoot.appending(path: "Resources/ghostty/themes/\(name)"), encoding: .utf8)
            let file = try #require(ThemeFileColors(name: name, themeFile: text), "\(name) has no colors")
            var input = ThemeInput(background: file.background, foreground: file.foreground,
                                   palette: file.palette.compactMap { $0 },
                                   selectionBackground: file.selectionBackground,
                                   selectionForeground: file.selectionForeground, cursor: file.cursorColor)
            input.accent = accent
            input.accentColor = file.accent
            return (name, input)
        }
    }

    @Test func theBandHoldsOrangesAndLeavesOutRedsYellowsBluesAndGreys() {
        for hex: UInt32 in [0xE8743B, 0xFF9500, 0xFF9F0A, 0xD87657, 0xF28C28] {
            #expect(Self.isOrange(ThemeRGB(hex: hex)), "\(ThemeRGB(hex: hex)) is orange")
        }
        for hex: UInt32 in [0xFF3B30, 0xFF453A, 0xCC372E, 0xFFCC00, 0xFFD60A, 0xCDAC08, 0xE5BC00, 0x0A84FF,
                            0xFFFFFF, 0x000000, 0xFCFCFC, 0x8A8580] {
            #expect(!Self.isOrange(ThemeRGB(hex: hex)), "\(ThemeRGB(hex: hex)) is not orange")
        }
    }

    @Test @MainActor func theDefaultThemesAccentTokensAreNeverOrange() throws {
        for (name, input) in try Self.defaultInputs() {
            let tokens = ThemeTokens.derive(from: input)
            let chrome: [(String, ThemeRGB)] = [
                ("accent", tokens.accent), ("focusRing", tokens.focusRing), ("selectionFill", tokens.selectionFill),
                ("secondarySelectionFill", tokens.secondarySelectionFill), ("highlight", tokens.highlight),
                ("textSelection", tokens.textSelection),
            ]
            let app: [(String, ThemeRGB)] = [AppTheme.Token.accent, .accentText, .focusRing, .selection]
                .map { ("app.\($0)", tokens.app[$0]) }
            for (token, color) in chrome + app {
                #expect(!Self.isOrange(color), "\(name): \(token) \(color) is orange")
            }
            // Pages read the same tokens: WebTheme's accent variables are these colors.
            let variables = WebTheme(tokens).variables
            #expect(variables["--cmux-accent"] == WebTheme.css(tokens.accent))
            #expect(variables["--cmux-selection"] == WebTheme.css(tokens.selectionFill))
            for token in [AppTheme.Token.accent, .accentText, .focusRing, .selection] {
                let css = try #require(tokens.app.cssVariables[token.variable], "no \(token.variable)")
                let color = try #require(ThemeRGB(cssHex: css), "\(token.variable) \(css)")
                #expect(!Self.isOrange(color), "\(name): \(token.variable) \(css) is orange")
            }
        }
    }
}

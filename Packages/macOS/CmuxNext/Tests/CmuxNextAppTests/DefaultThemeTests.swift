import Foundation
@testable import CmuxNextOnboarding
@testable import CmuxNextTerminal
import Testing

/// cmux-next's default terminal theme differs from Ghostty's: Apple System
/// Colors (dark) / Apple System Colors Light (light), loaded before the
/// user's Ghostty config so their own theme or colors still win.
@MainActor @Suite(.serialized) struct DefaultThemeTests {
    /// The checked-in Ghostty resources the app bundles
    /// (scripts/cmux-next/bundle-ghostty-resources.sh).
    private static var themesFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../../Resources/ghostty/themes").standardizedFileURL
    }

    /// The default's colors with the repo's theme files (by absolute path,
    /// so neither the host's Ghostty.app nor ~/.config/ghostty/themes can
    /// stand in).
    private static func colors(_ text: String) -> GhosttyThemeColors? {
        _ = GhosttyRuntime.shared
        return GhosttyRuntime.themeColors(configText: text, themesFolder: themesFolder)
    }

    private static func hex(_ rgb: GhosttyThemeColors.RGB?) -> String {
        guard let rgb else { return "-" }
        return String(format: "#%02x%02x%02x", rgb.r, rgb.g, rgb.b)
    }

    /// Fails when a Ghostty bump renames or drops the default's themes.
    @Test func bothDefaultThemesShipWithGhostty() throws {
        for (name, background) in [(GhosttyRuntime.defaultDarkThemeName, "#1e1e1e"), (GhosttyRuntime.defaultLightThemeName, "#feffff")] {
            let file = Self.themesFolder.appending(path: name)
            let text = try String(contentsOf: file, encoding: .utf8)
            let input = try #require(GhosttyThemeFile.parse(text), "\(name) does not parse")
            #expect(String(format: "#%02x%02x%02x", Int(input.background.red * 255), Int(input.background.green * 255),
                           Int(input.background.blue * 255)) == background, "\(name)")
        }
        #expect(GhosttyRuntime.defaultThemeSpec == "light:Apple System Colors Light,dark:Apple System Colors")
    }

    @Test func aConfigWithoutAThemeGetsTheDefault() throws {
        let colors = try #require(Self.colors(""))
        // A bare config resolves the light variant; the app's color scheme
        // picks the dark one live.
        #expect(Self.hex(colors.background) == "#feffff")
        #expect(Self.hex(colors.foreground) == "#000000")
    }

    @Test func theUsersThemeAndColorsWin() throws {
        let theirs = try #require(Self.colors("theme = \(Self.themesFolder.appending(path: "Nord").path)\n"))
        #expect(Self.hex(theirs.background) == "#2e3440")
        let explicit = try #require(Self.colors("background = #123456\n"))
        #expect(Self.hex(explicit.background) == "#123456")
    }

    /// The default theme loads before the user's config, so their theme
    /// and translucency (`background-blur`) win over it, whatever order
    /// the lines come in.
    @Test func theUsersThemeAndBlurWinOverTheDefault() throws {
        let theme = "theme = \(Self.themesFolder.appending(path: "Catppuccin Mocha").path)"
        for text in ["\(theme)\nbackground-opacity = 0.85\nbackground-blur = 20\n", "background-blur = 20\nbackground-opacity = 0.85\n\(theme)\n"] {
            let colors = try #require(Self.colors(text))
            #expect(Self.hex(colors.background) == "#1e1e2e")
            #expect(colors.backgroundBlur == 20)
        }
    }
}

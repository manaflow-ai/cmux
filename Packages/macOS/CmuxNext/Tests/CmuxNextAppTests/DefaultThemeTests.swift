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

    private static func withResources<T>(_ body: () throws -> T) rethrows -> T {
        _ = GhosttyRuntime.shared
        let previous = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]
        setenv("GHOSTTY_RESOURCES_DIR", themesFolder.deletingLastPathComponent().path, 1)
        defer { if let previous { setenv("GHOSTTY_RESOURCES_DIR", previous, 1) } else { unsetenv("GHOSTTY_RESOURCES_DIR") } }
        return try body()
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
        let colors = try Self.withResources { try #require(GhosttyRuntime.themeColors(configText: "")) }
        // A bare config resolves the light variant; the app's color scheme
        // picks the dark one live.
        #expect(Self.hex(colors.background) == "#feffff")
        #expect(Self.hex(colors.foreground) == "#000000")
    }

    @Test func theUsersThemeAndColorsWin() throws {
        let theirs = try Self.withResources { try #require(GhosttyRuntime.themeColors(configText: "theme = Nord\n")) }
        #expect(Self.hex(theirs.background) == "#2e3440")
        let explicit = try Self.withResources { try #require(GhosttyRuntime.themeColors(configText: "background = #123456\n")) }
        #expect(Self.hex(explicit.background) == "#123456")
    }
}

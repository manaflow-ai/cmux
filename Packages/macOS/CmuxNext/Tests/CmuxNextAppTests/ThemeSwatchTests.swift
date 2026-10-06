import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Theme swatch strips for the theme pickers (R98): read from the Ghostty
/// theme files off the main thread, kept per theme, and listed with the
/// palette's theme setting values.
@MainActor @Suite struct ThemeSwatchTests {
    private let mocha = """
        # a comment = ignored
        palette = 0=#45475a
        palette = 1=#f38ba8
        palette = 2=#a6e3a1
        palette = 3=#f9e2af
        palette = 4=#89b4fa
        palette = 5=#f5c2e7
        palette = 6=#94e2d5
        palette = 7=#a6adc8
        background = #1e1e2e
        foreground = cdd6f4
        cursor-color = #f5e0dc
        """

    @Test func aStripIsBackgroundSixAnsiColorsAndForeground() {
        let strip = ThemeSwatch.strip(themeFile: mocha)
        let hex = ["#1e1e2e", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#cdd6f4"]
        #expect(strip == hex.compactMap { ThemeRGB(cssHex: $0) })
    }

    @Test func missingColorsAreLeftOut() {
        #expect(ThemeSwatch.strip(themeFile: "background = #000000\npalette = 2=#00ff00\nbogus line\n")
            == [ThemeRGB(hex: 0x000000), ThemeRGB(hex: 0x00FF00)])
        #expect(ThemeSwatch.strip(themeFile: "font-size = 12\n").isEmpty)
    }

    @Test func catalogStripsReadEveryThemeAndTheUsersFileWins() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-swatches-\(UUID().uuidString)")
        let resources = root.appending(path: "resources")
        let shipped = resources.appending(path: "themes")
        let user = root.appending(path: "config/ghostty/themes")
        for folder in [shipped, user] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("background = #111111\n".utf8).write(to: shipped.appending(path: "Shared"))
        try Data("background = #222222\n".utf8).write(to: shipped.appending(path: "Shipped"))
        try Data("background = #333333\n".utf8).write(to: user.appending(path: "Shared"))
        let strips = ThemeCatalog.strips(resources: resources.path, home: root,
                                         environment: ["XDG_CONFIG_HOME": root.appending(path: "config").path])
        #expect(strips["Shipped"] == [ThemeRGB(hex: 0x222222)])
        #expect(strips["Shared"] == [ThemeRGB(hex: 0x333333)])
        #expect(strips.count == 2)
    }

    @Test func themeSettingListsTheConfigCuratedThenEveryThemeWithStrips() throws {
        let names = ["Zenburn", "Nord", "3024 Day"]
        let options = SettingsPaletteSource.themeOptions(current: "Zenburn", names: names, defaultLabel: "Ghostty config") { name in
            name == "Zenburn" ? [ThemeRGB(hex: 0x3F3F3F)] : []
        }
        // Reset first, then onboarding's themes that exist, then the rest.
        #expect(options.map(\.title) == ["Ghostty config", "Nord", "Zenburn", "3024 Day"])
        #expect(options.first?.value == nil)
        let zenburn = try #require(options.first { $0.title == "Zenburn" })
        #expect(zenburn.isCurrent && zenburn.value == .string("Zenburn"))
        #expect(zenburn.swatches == [ThemeRGB(hex: 0x3F3F3F)])
        #expect(options.filter(\.isCurrent).count == 1)
    }

    @Test func anUnlistedThemeValueStaysCurrent() {
        let options = SettingsPaletteSource.themeOptions(current: "light:Nord,dark:Zenburn", names: ["Nord"],
                                                         defaultLabel: "Ghostty config") { _ in [] }
        #expect(options.map(\.title) == ["Ghostty config", "light:Nord,dark:Zenburn", "Nord"])
        #expect(options[1].isCurrent && !options[0].isCurrent)
        let reset = SettingsPaletteSource.themeOptions(current: nil, names: ["Nord"], defaultLabel: "Ghostty config") { _ in [] }
        #expect(reset.first?.isCurrent == true)
    }
}

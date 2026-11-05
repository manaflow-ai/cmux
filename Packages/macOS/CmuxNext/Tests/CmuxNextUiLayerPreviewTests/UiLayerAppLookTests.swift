// The preview leaf is Debug-only (CMUX_UI_LAYER_PREVIEW); in Release this
// target builds with no tests.
#if CMUX_UI_LAYER_PREVIEW
import CmuxTheme
import Foundation
import Testing
@testable import CmuxNextUiLayerPreview

@MainActor
@Suite struct UiLayerAppLookTests {
    private let theme = """
    background = #102030
    foreground = #e0e0e0
    palette = 4=#3366ff
    # cmux-accent = #ff8800
    """

    /// A home with the app's settings file, a Ghostty config and a themes folder.
    private func home(settings: String, ghostty: String?) throws -> (home: URL, themes: URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "ui-layer-look-\(UUID().uuidString)")
        let config = home.appending(path: ".config")
        let themes = home.appending(path: "themes")
        try FileManager.default.createDirectory(at: config.appending(path: "cmux"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.appending(path: "ghostty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try settings.write(to: config.appending(path: "cmux/cmux-next.json"), atomically: true, encoding: .utf8)
        if let ghostty { try ghostty.write(to: config.appending(path: "ghostty/config"), atomically: true, encoding: .utf8) }
        try theme.write(to: themes.appending(path: "Harbor Night"), atomically: true, encoding: .utf8)
        return (home, themes)
    }

    @Test func readsTheAppsThemeOpacityAndBackground() throws {
        let (home, themes) = try home(
            settings: """
            // JSONC, as people write it
            { "appearance": { "theme": "light:Missing Light,dark:Harbor Night", "backgroundOpacity": 0.7,
                              "background": "desktop", "accent": "blue" } }
            """,
            ghostty: "theme = Something Else\nbackground-blur = 12\n"
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let look = UiLayerAppLook.load(isDark: true, home: home,
                                       environment: ["CMUX_UI_LAYER_THEMES": themes.path], applicationFolders: [])

        #expect(look.themeName == "Harbor Night")
        #expect(look.input.background == ThemeRGB(cssHex: "#102030"))
        #expect(look.input.palette[4] == ThemeRGB(cssHex: "#3366ff"))
        #expect(look.input.accentColor == ThemeRGB(cssHex: "#ff8800"))
        #expect(look.input.backgroundOpacity == 0.7)
        #expect(look.accent == .blue)
        #expect(look.backdrop != nil)
    }

    @Test func fallsBackToTheGhosttyConfigTheme() throws {
        let (home, themes) = try home(settings: "{}", ghostty: "theme = Harbor Night\nforeground = #ffffff\n")
        defer { try? FileManager.default.removeItem(at: home) }
        let look = UiLayerAppLook.load(isDark: false, home: home,
                                       environment: ["CMUX_UI_LAYER_THEMES": themes.path], applicationFolders: [])

        #expect(look.themeName == "Harbor Night")
        // The config's own color wins over the theme file's.
        #expect(look.input.foreground == ThemeRGB(cssHex: "#ffffff"))
        #expect(look.backdrop == nil)
    }

    @Test func ghosttyConfigLaterLinesWin() {
        var config = UiLayerGhosttyConfig(themeSpec: UiLayerAppLook.defaultThemeSpec)
        config.read("""
        background-blur = true
        background-opacity = 1.5
        theme = "Nord"
        background-blur = macos-glass-clear
        """)
        #expect(config.themeSpec == "Nord")
        #expect(config.backgroundOpacity == 1)
        #expect(config.backgroundBlur == -2)
        #expect(UiLayerGhosttyConfig.blur("false") == 0)
        #expect(UiLayerGhosttyConfig.blur("nonsense") == nil)
    }
}
#endif

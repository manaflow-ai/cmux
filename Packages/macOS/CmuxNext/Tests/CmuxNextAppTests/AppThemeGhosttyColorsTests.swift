import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal
import CmuxNextDesignTokens

/// A Ghostty config that sets its own colors (`background = #000000`) keeps them in the terminals,
/// as in Ghostty, but the App Theme is cmux's own: the window, sidebar and tabs take the App
/// Theme's colors and the person's edits to it, never the terminal config's color lines.
/// Reproduced on a fleet mini: App Theme Catppuccin Latte with `background = #000000` and
/// `foreground = #00ff00` in the Ghostty config drew the whole window black with green text.
@MainActor
@Suite(.serialized)
struct AppThemeGhosttyColorsTests {
    private static let themeText = """
        background = #eff1f5
        foreground = #4c4f69
        palette = 0=#5c5f77
        palette = 4=#1e66f5

        """

    @Test func theAppThemeTakesItsFileColorsNotTheConfigsColorLines() throws {
        _ = GhosttyRuntime.shared  // ghostty_config_new requires ghostty_init
        let directory = FileManager.default.temporaryDirectory.appending(path: "app-theme-ghostty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let theme = directory.appending(path: "Latte")
        try Data(Self.themeText.utf8).write(to: theme)
        let config = directory.appending(path: "config")
        try Data("background = #000000\nforeground = #00ff00\n".utf8).write(to: config)

        // The terminals: the config's own colors win over the theme, as in Ghostty.
        var diagnostics: [String] = []
        var opacity = 1.0
        let terminal = try #require(GhosttyRuntime.loadConfig(diagnostics: &diagnostics, opacity: &opacity,
                                                              theme: theme.path, configFile: config.path))
        defer { ghostty_config_free(terminal) }
        let terminalColors = try #require(GhosttyRuntime.themeColors(of: terminal, backgroundOpacity: 1))
        #expect(terminalColors.background == .init(r: 0, g: 0, b: 0))

        // The App Theme: the theme file's colors.
        let app = try #require(GhosttyRuntime.appThemeColors(theme: theme.path, edits: .none))
        #expect(app.background == .init(r: 0xEF, g: 0xF1, b: 0xF5))
        #expect(app.foreground == .init(r: 0x4C, g: 0x4F, b: 0x69))
        #expect(app.palette.count == 16)
        #expect(app.palette[4] == .init(r: 0x1E, g: 0x66, b: 0xF5))

        // The person's edits to that theme (appearance.themeEdits) still apply.
        let edited = try #require(GhosttyRuntime.appThemeColors(
            theme: theme.path, edits: ThemeEdits([theme.path: ["background": "#112233"]])))
        #expect(edited.background == .init(r: 0x11, g: 0x22, b: 0x33))
        #expect(edited.foreground == .init(r: 0x4C, g: 0x4F, b: 0x69))
    }
}

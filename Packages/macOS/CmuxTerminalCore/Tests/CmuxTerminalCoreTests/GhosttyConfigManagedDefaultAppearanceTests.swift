import AppKit
import Foundation
import Testing
@testable import CmuxTerminalCore

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7161.
///
/// cmux applies its managed default terminal theme ("Apple System Colors")
/// whenever the user has not chosen a `theme` themselves. Individual explicit
/// color keys such as a lone `background = black` must NOT suppress the managed
/// theme: Ghostty's documented semantics are that explicit color keys override
/// only those colors on top of the active theme. Before the fix, any color
/// directive made cmux skip the managed theme entirely, so Ghostty silently
/// fell back to its built-in default palette and all 16 ANSI colors plus the
/// foreground changed from a single `background` override.
@Suite struct GhosttyConfigManagedDefaultAppearanceTests {
    private func withTempConfigDir(
        body: (_ dir: URL) throws -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-7161-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func withTempConfig(
        _ contents: String,
        body: (_ path: String) throws -> Void
    ) throws {
        try withTempConfigDir { dir in
            let file = dir.appendingPathComponent("config", isDirectory: false)
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try body(file.path)
        }
    }

    // MARK: Managed-default-theme gate (issue #7161)

    @Test func backgroundOnlyConfigStillAppliesManagedDefaultTheme() throws {
        try withTempConfig("background = black\n") { path in
            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(configPaths: [path]))
        }
    }

    @Test func paletteAndCursorColorConfigStillAppliesManagedDefaultTheme() throws {
        try withTempConfig(
            """
            palette = 1=#ff0000
            cursor-color = #ffcc00
            selection-background = #333333
            """
        ) { path in
            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(configPaths: [path]))
        }
    }

    @Test func explicitColorInIncludedConfigFileStillAppliesManagedDefaultTheme() throws {
        try withTempConfigDir { dir in
            let included = dir.appendingPathComponent("appearance.conf", isDirectory: false)
            try "background = #101820\n".write(to: included, atomically: true, encoding: .utf8)

            let main = dir.appendingPathComponent("config", isDirectory: false)
            try "config-file = appearance.conf\n".write(to: main, atomically: true, encoding: .utf8)

            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(configPaths: [main.path]))
        }
    }

    @Test func explicitThemeSuppressesManagedDefaultTheme() throws {
        try withTempConfig("theme = Catppuccin Mocha\n") { path in
            #expect(!GhosttyConfig.shouldApplyManagedDefaultAppearance(configPaths: [path]))
        }
    }

    @Test func explicitThemeWithColorOverridesSuppressesManagedDefaultTheme() throws {
        try withTempConfig("theme = Catppuccin Mocha\nbackground = black\n") { path in
            #expect(!GhosttyConfig.shouldApplyManagedDefaultAppearance(configPaths: [path]))
        }
    }

    @Test func nonAppearanceConfigAppliesManagedDefaultTheme() throws {
        try withTempConfig("font-family = JetBrains Mono\nbackground-opacity = 0.92\n") { path in
            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(configPaths: [path]))
        }
    }

    // MARK: Managed base + user override precedence

    /// Writes sentinel "Apple System Colors" theme files into a themes root the
    /// managed-default resolution finds via `GHOSTTY_RESOURCES_DIR`, keeping the
    /// resolved managed colors deterministic on machines with Ghostty installed.
    private func makeManagedThemesRoot(in dir: URL) throws -> URL {
        let root = dir.appendingPathComponent("resources", isDirectory: true)
        let themesDir = root.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)

        let managedTheme = """
        palette = 1=#c0ffee
        background = #112233
        foreground = #445566
        cursor-color = #778899
        """
        for name in [GhosttyConfig.cmuxDefaultDarkThemeName, GhosttyConfig.cmuxDefaultLightThemeName] {
            try managedTheme.write(
                to: themesDir.appendingPathComponent(name, isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    private func loadResolvedConfig(
        userConfig: String,
        body: (GhosttyConfig) throws -> Void
    ) throws {
        try withTempConfigDir { dir in
            let themesRoot = try makeManagedThemesRoot(in: dir)
            let file = dir.appendingPathComponent("config", isDirectory: false)
            try userConfig.write(to: file, atomically: true, encoding: .utf8)

            var config = GhosttyConfig()
            config.loadResolvedUserConfig(
                configPaths: [file.path],
                preferredColorScheme: .dark,
                environment: ["GHOSTTY_RESOURCES_DIR": themesRoot.path],
                bundleResourceURL: nil
            )
            try body(config)
        }
    }

    @Test func managedDefaultThemeAppliedWhenNoAppearanceDirectives() throws {
        try loadResolvedConfig(userConfig: "font-family = JetBrains Mono\n") { config in
            #expect(config.theme == nil)
            #expect(config.backgroundColor.hexString() == "#112233")
            #expect(config.foregroundColor.hexString() == "#445566")
            #expect(config.palette[1]?.hexString() == "#C0FFEE")
        }
    }

    /// The issue-#7161 repro: a lone `background` override must keep the rest
    /// of the managed default theme instead of swapping the entire palette.
    @Test func backgroundOverrideKeepsManagedPaletteAndForeground() throws {
        try loadResolvedConfig(userConfig: "background = #000000\n") { config in
            #expect(config.theme == nil)
            #expect(config.backgroundColor.hexString() == "#000000")
            #expect(config.foregroundColor.hexString() == "#445566")
            #expect(config.palette[1]?.hexString() == "#C0FFEE")
            #expect(config.cursorColor.hexString() == "#778899")
        }
    }

    @Test func explicitThemeDirectiveSkipsManagedDefaultBase() throws {
        let defaultBackgroundHex = GhosttyConfig().backgroundColor.hexString()
        try loadResolvedConfig(userConfig: "theme = Cmux Nonexistent Theme 7161\n") { config in
            #expect(config.theme == "Cmux Nonexistent Theme 7161")
            // The unresolvable user theme leaves the built-in defaults in place;
            // the managed base must not have been applied underneath it.
            #expect(config.backgroundColor.hexString() == defaultBackgroundHex)
            #expect(config.palette[1] == nil)
        }
    }
}

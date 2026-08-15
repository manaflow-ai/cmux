import AppKit
import Foundation
import Testing
@testable import CmuxTerminalCore

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7161
/// and https://github.com/manaflow-ai/cmux/issues/10199.
///
/// cmux's managed default terminal theme ("Apple System Colors") is opt-in.
/// When opted out, Ghostty's fixed built-in colors remain the base. When opted
/// in, individual explicit color keys such as a lone `background = black` do
/// not suppress the managed theme: they override only those colors on top of
/// the active managed base, preserving the behavior fixed by issue #7161.
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

    @Test func managedDefaultThemeRequiresExplicitOptIn() throws {
        try withTempConfig("background = black\n") { path in
            #expect(!GhosttyConfig.shouldApplyManagedDefaultAppearance(configPaths: [path]))
        }
    }

    @Test func loadCacheSeparatesAdaptiveDefaultThemeChoices() {
        GhosttyConfig.invalidateLoadCache()
        defer { GhosttyConfig.invalidateLoadCache() }

        var loadCount = 0
        let loadFromDisk: (
            GhosttyConfig.ColorSchemePreference,
            Bool
        ) -> GhosttyConfig = { _, adaptiveDefaultThemeEnabled in
            loadCount += 1
            var config = GhosttyConfig()
            config.fontFamily = adaptiveDefaultThemeEnabled ? "adaptive" : "ghostty"
            return config
        }

        let ghosttyDefault = GhosttyConfig.load(
            preferredColorScheme: .dark,
            adaptiveDefaultThemeEnabled: false,
            loadFromDisk: loadFromDisk
        )
        let adaptiveFirst = GhosttyConfig.load(
            preferredColorScheme: .dark,
            adaptiveDefaultThemeEnabled: true,
            loadFromDisk: loadFromDisk
        )
        let adaptiveSecond = GhosttyConfig.load(
            preferredColorScheme: .dark,
            adaptiveDefaultThemeEnabled: true,
            loadFromDisk: loadFromDisk
        )

        #expect(loadCount == 2)
        #expect(ghosttyDefault.fontFamily == "ghostty")
        #expect(adaptiveFirst.fontFamily == "adaptive")
        #expect(adaptiveSecond.fontFamily == "adaptive")
    }

    @Test func optedInColorOverridesRemainEligibleForManagedDefaultTheme() throws {
        try withTempConfig(
            """
            palette = 1=#ff0000
            cursor-color = #ffcc00
            selection-background = #333333
            """
        ) { path in
            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func optedInIncludedColorRemainsEligibleForManagedDefaultTheme() throws {
        try withTempConfigDir { dir in
            let included = dir.appendingPathComponent("appearance.conf", isDirectory: false)
            try "background = #101820\n".write(to: included, atomically: true, encoding: .utf8)

            let main = dir.appendingPathComponent("config", isDirectory: false)
            try "config-file = appearance.conf\n".write(to: main, atomically: true, encoding: .utf8)

            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [main.path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func explicitThemeSuppressesManagedDefaultTheme() throws {
        try withTempConfig("theme = Catppuccin Mocha\n") { path in
            #expect(!GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func explicitThemeWithColorOverridesSuppressesManagedDefaultTheme() throws {
        try withTempConfig("theme = Catppuccin Mocha\nbackground = black\n") { path in
            #expect(!GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func nonAppearanceConfigAppliesManagedDefaultTheme() throws {
        try withTempConfig("font-family = JetBrains Mono\nbackground-opacity = 0.92\n") { path in
            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    /// The summary still tracks explicit color directives separately: the runtime
    /// uses that flag to re-assert the managed default over a stale legacy
    /// app-support config only when the user set no appearance directives at all.
    @Test func summaryTracksColorDirectivesWithoutSuppressingManagedDefault() throws {
        try withTempConfig("background = black\n") { path in
            let summary = GhosttyConfig.userAppearanceConfigSummary(configPaths: [path])
            #expect(summary.shouldApplyDefaultAppearance)
            #expect(summary.hasExplicitTerminalColorDirective)
        }
    }

    @Test func summaryReportsNoColorDirectivesForNonAppearanceConfig() throws {
        try withTempConfig("font-family = JetBrains Mono\nbackground-opacity = 0.92\n") { path in
            let summary = GhosttyConfig.userAppearanceConfigSummary(configPaths: [path])
            #expect(summary.shouldApplyDefaultAppearance)
            #expect(!summary.hasExplicitTerminalColorDirective)
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
        adaptiveDefaultThemeEnabled: Bool = false,
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
                adaptiveDefaultThemeEnabled: adaptiveDefaultThemeEnabled,
                environment: ["GHOSTTY_RESOURCES_DIR": themesRoot.path],
                bundleResourceURL: nil
            )
            try body(config)
        }
    }

    @Test func ghosttyDefaultsApplyWhenManagedThemeIsOff() throws {
        try loadResolvedConfig(userConfig: "font-family = JetBrains Mono\n") { config in
            #expect(config.theme == nil)
            #expect(config.backgroundColor.hexString() == "#282C34")
            #expect(config.foregroundColor.hexString() == "#FFFFFF")
            #expect(config.palette[1]?.hexString() == "#CC6666")
        }
    }

    @Test func managedDefaultThemeAppliedWhenOptedIn() throws {
        try loadResolvedConfig(
            userConfig: "font-family = JetBrains Mono\n",
            adaptiveDefaultThemeEnabled: true
        ) { config in
            #expect(config.theme == nil)
            #expect(config.backgroundColor.hexString() == "#112233")
            #expect(config.foregroundColor.hexString() == "#445566")
            #expect(config.palette[1]?.hexString() == "#C0FFEE")
        }
    }

    @Test func optedInManagedDefaultTracksAppearance() throws {
        try withTempConfigDir { dir in
            let themesRoot = dir.appendingPathComponent("resources", isDirectory: true)
            let themesDir = themesRoot.appendingPathComponent("themes", isDirectory: true)
            try FileManager.default.createDirectory(
                at: themesDir,
                withIntermediateDirectories: true
            )
            try "background = #FAFBFC\nforeground = #101112\n".write(
                to: themesDir.appendingPathComponent(
                    GhosttyConfig.cmuxDefaultLightThemeName
                ),
                atomically: true,
                encoding: .utf8
            )
            try "background = #090A0B\nforeground = #F0F1F2\n".write(
                to: themesDir.appendingPathComponent(
                    GhosttyConfig.cmuxDefaultDarkThemeName
                ),
                atomically: true,
                encoding: .utf8
            )
            let configURL = dir.appendingPathComponent("config")
            try "font-family = JetBrains Mono\n".write(
                to: configURL,
                atomically: true,
                encoding: .utf8
            )

            func load(_ colorScheme: GhosttyConfig.ColorSchemePreference) -> GhosttyConfig {
                var config = GhosttyConfig()
                config.loadResolvedUserConfig(
                    configPaths: [configURL.path],
                    preferredColorScheme: colorScheme,
                    adaptiveDefaultThemeEnabled: true,
                    environment: ["GHOSTTY_RESOURCES_DIR": themesRoot.path],
                    bundleResourceURL: nil
                )
                return config
            }

            let light = load(.light)
            let dark = load(.dark)
            #expect(light.backgroundColor.hexString() == "#FAFBFC")
            #expect(light.foregroundColor.hexString() == "#101112")
            #expect(dark.backgroundColor.hexString() == "#090A0B")
            #expect(dark.foregroundColor.hexString() == "#F0F1F2")
        }
    }

    @Test func backgroundOverrideKeepsGhosttyPaletteWhenManagedThemeIsOff() throws {
        try loadResolvedConfig(userConfig: "background = #000000\n") { config in
            #expect(config.theme == nil)
            #expect(config.backgroundColor.hexString() == "#000000")
            #expect(config.foregroundColor.hexString() == "#FFFFFF")
            #expect(config.palette[1]?.hexString() == "#CC6666")
        }
    }

    /// The issue-#7161 repro: a lone `background` override must keep the rest
    /// of the managed default theme instead of swapping the entire palette.
    @Test func backgroundOverrideKeepsManagedPaletteAndForeground() throws {
        try loadResolvedConfig(
            userConfig: "background = #000000\n",
            adaptiveDefaultThemeEnabled: true
        ) { config in
            #expect(config.theme == nil)
            #expect(config.backgroundColor.hexString() == "#000000")
            #expect(config.foregroundColor.hexString() == "#445566")
            #expect(config.palette[1]?.hexString() == "#C0FFEE")
            #expect(config.cursorColor.hexString() == "#778899")
        }
    }

    @Test func explicitThemeDirectiveSkipsManagedDefaultBase() throws {
        let defaultBackgroundHex = GhosttyConfig().backgroundColor.hexString()
        try loadResolvedConfig(
            userConfig: "theme = Cmux Nonexistent Theme 7161\n",
            adaptiveDefaultThemeEnabled: true
        ) { config in
            #expect(config.theme == "Cmux Nonexistent Theme 7161")
            // The unresolvable user theme leaves the built-in defaults in place;
            // the managed base must not have been applied underneath it.
            #expect(config.backgroundColor.hexString() == defaultBackgroundHex)
            #expect(config.palette[1]?.hexString() == "#CC6666")
        }
    }
}

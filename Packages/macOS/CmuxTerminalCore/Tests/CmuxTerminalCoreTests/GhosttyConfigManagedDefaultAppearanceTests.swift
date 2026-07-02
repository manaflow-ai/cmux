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
}

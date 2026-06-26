import AppKit
import CmuxFoundation
import Foundation
import Testing
@testable import CmuxTerminalCore

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/6411.
///
/// cmux paints the terminal background from its host layer
/// (`macos-background-from-layer = true`) using the color the Swift
/// ``GhosttyConfig`` parser resolves, while Ghostty renders the foreground text
/// from the surface config it is handed. A conditional `theme = light:…/dark:…`
/// value only applies to the appearance side that matches the active color
/// scheme — Ghostty leaves the opposite side's foreground at its default
/// (near-white) and the terminal surface deliberately does not inject an
/// override for an unspecified side (see ``GhosttyConfig/explicitConditionalThemeName(from:preferredColorScheme:)``).
///
/// The host-layer background resolver must follow the same rule. When it instead
/// cross-side fell back to the other appearance's theme, cmux painted a light
/// theme's near-white background under Ghostty's default near-white foreground,
/// producing the unreadable white-on-white terminals reported in #6411.
@Suite struct GhosttyConfigConditionalThemeApplicationTests {
    /// A light theme directory (light background, dark foreground) reachable via
    /// `GHOSTTY_RESOURCES_DIR`.
    private static let lightThemeBackgroundHex = "#FDF6E3"

    private func makeThemesRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-6411-\(UUID().uuidString)", isDirectory: true)
        let themesDir = root.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        try """
        background = #fdf6e3
        foreground = #657b83
        """.write(
            to: themesDir.appendingPathComponent("Light Theme", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    /// A one-sided `theme = light:X` must NOT paint X's background in the dark
    /// appearance. Painting it there left the surface foreground at Ghostty's
    /// default near-white, producing white-on-white (#6411).
    @Test func oneSidedLightThemeIsNotAppliedInDarkAppearance() throws {
        let root = try makeThemesRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultBackgroundHex = GhosttyConfig().backgroundColor.hexString()

        var darkConfig = GhosttyConfig()
        darkConfig.loadTheme(
            "light:Light Theme",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil,
            preferredColorScheme: .dark
        )

        #expect(
            darkConfig.backgroundColor.hexString()
                .caseInsensitiveCompare(Self.lightThemeBackgroundHex) != .orderedSame
        )
        #expect(darkConfig.backgroundColor.hexString() == defaultBackgroundHex)
    }

    /// The one-sided light theme still applies in its own (light) appearance.
    @Test func oneSidedLightThemeIsAppliedInLightAppearance() throws {
        let root = try makeThemesRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var lightConfig = GhosttyConfig()
        lightConfig.loadTheme(
            "light:Light Theme",
            environment: ["GHOSTTY_RESOURCES_DIR": root.path],
            bundleResourceURL: nil,
            preferredColorScheme: .light
        )

        #expect(
            lightConfig.backgroundColor.hexString()
                .caseInsensitiveCompare(Self.lightThemeBackgroundHex) == .orderedSame
        )
    }
}

/// Unit coverage for the per-appearance theme resolution that backs the host
/// layer background (the #6411 fix). Unlike ``GhosttyConfig/resolveThemeName(from:preferredColorScheme:)``
/// it must never cross-side fall back from one appearance to the other.
@Suite struct GhosttyConfigAppliedThemeNameTests {
    @Test func oneSidedLightThemeResolvesOnlyForLight() {
        #expect(
            GhosttyConfig.appliedThemeName(from: "light:GitHub Light Default", preferredColorScheme: .light)
                == "GitHub Light Default"
        )
        #expect(
            GhosttyConfig.appliedThemeName(from: "light:GitHub Light Default", preferredColorScheme: .dark)
                == nil
        )
    }

    @Test func oneSidedDarkThemeResolvesOnlyForDark() {
        #expect(
            GhosttyConfig.appliedThemeName(from: "dark:Catppuccin Mocha", preferredColorScheme: .dark)
                == "Catppuccin Mocha"
        )
        #expect(
            GhosttyConfig.appliedThemeName(from: "dark:Catppuccin Mocha", preferredColorScheme: .light)
                == nil
        )
    }

    @Test func bothSidedThemeResolvesEachSide() {
        #expect(
            GhosttyConfig.appliedThemeName(from: "light:Catppuccin Latte,dark:Catppuccin Mocha", preferredColorScheme: .light)
                == "Catppuccin Latte"
        )
        #expect(
            GhosttyConfig.appliedThemeName(from: "light:Catppuccin Latte,dark:Catppuccin Mocha", preferredColorScheme: .dark)
                == "Catppuccin Mocha"
        )
    }

    @Test func identicalPairFromCLIEncodingResolvesInBothSchemes() {
        // `cmux themes set --light X --dark X` writes `light:X,dark:X`; both
        // appearances must resolve X so the forced theme applies everywhere.
        let value = "light:GitHub Light Default,dark:GitHub Light Default"
        #expect(GhosttyConfig.appliedThemeName(from: value, preferredColorScheme: .light) == "GitHub Light Default")
        #expect(GhosttyConfig.appliedThemeName(from: value, preferredColorScheme: .dark) == "GitHub Light Default")
    }

    @Test func plainThemeAppliesInEveryScheme() {
        #expect(GhosttyConfig.appliedThemeName(from: "Catppuccin Mocha", preferredColorScheme: .light) == "Catppuccin Mocha")
        #expect(GhosttyConfig.appliedThemeName(from: "Catppuccin Mocha", preferredColorScheme: .dark) == "Catppuccin Mocha")
    }

    @Test func unconditionalBaseAppliesWhenSideUnspecified() {
        // An unconditional base is the documented fallback; the *opposite*
        // conditional side is not.
        #expect(GhosttyConfig.appliedThemeName(from: "Catppuccin Mocha,light:Catppuccin Latte", preferredColorScheme: .dark) == "Catppuccin Mocha")
    }
}

import AppKit
import Foundation
import Testing
@testable import CmuxTerminalCore

/// Verifies that cmux preserves configured Ghostty colors while retaining its
/// adaptive managed palette for an untouched Ghostty configuration
/// (https://github.com/manaflow-ai/cmux/issues/10199).
@Suite struct GhosttyConfigThemeParityTests {
    enum Scenario: String, CaseIterable, Sendable {
        case noConfig
        case nonAppearanceSetting
        case partialExplicitColors
        case fullExplicitColors
        case singleTheme
        case conditionalThemePair
    }

    private struct ColorSnapshot: Equatable {
        let foreground: String
        let background: String
        let cursor: String
        let cursorText: String
        let selectionBackground: String
        let selectionForeground: String
        let palette: [Int: String]
    }

    private struct ScenarioFixture {
        let configContents: String
        let light: ColorSnapshot
        let dark: ColorSnapshot
        let changesWithAppearance: Bool
    }

    private static let ghosttyDefaultPalette = [
        "#1D1F21", "#CC6666", "#B5BD68", "#F0C674",
        "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
        "#666666", "#D54E53", "#B9CA4A", "#E7C547",
        "#7AA6DA", "#C397D8", "#70C0B1", "#EAEAEA",
    ]

    private static let managedLightPalette = [
        "#1A1A1A", "#CC372E", "#26A439", "#CDAC08",
        "#0869CB", "#9647BF", "#479EC2", "#98989D",
        "#464646", "#FF453A", "#32D74B", "#E5BC00",
        "#0A84FF", "#BF5AF2", "#69C9F2", "#FFFFFF",
    ]

    private static let managedDarkPalette = [
        "#1A1A1A", "#CC372E", "#26A439", "#CDAC08",
        "#0869CB", "#9647BF", "#479EC2", "#98989D",
        "#464646", "#FF453A", "#32D74B", "#FFD60A",
        "#0A84FF", "#BF5AF2", "#76D6FF", "#FFFFFF",
    ]

    private static let fullExplicitPalette = [
        "#010101", "#111111", "#212121", "#313131",
        "#414141", "#515151", "#616161", "#717171",
        "#818181", "#919191", "#A1A1A1", "#B1B1B1",
        "#C1C1C1", "#D1D1D1", "#E1E1E1", "#F1F1F1",
    ]

    private static let singleThemePalette = [
        "#001100", "#112200", "#223300", "#334400",
        "#445500", "#556600", "#667700", "#778800",
        "#889900", "#99AA00", "#AABB00", "#BBCC00",
        "#CCDD00", "#DDEE00", "#EEFF00", "#FFFF00",
    ]

    private static let lightThemePalette = [
        "#100001", "#200002", "#300003", "#400004",
        "#500005", "#600006", "#700007", "#800008",
        "#900009", "#A0000A", "#B0000B", "#C0000C",
        "#D0000D", "#E0000E", "#F0000F", "#FF0010",
    ]

    private static let darkThemePalette = [
        "#000110", "#000220", "#000330", "#000440",
        "#000550", "#000660", "#000770", "#000880",
        "#000990", "#000AA0", "#000BB0", "#000CC0",
        "#000DD0", "#000EE0", "#000FF0", "#0010FF",
    ]

    @Test(arguments: Scenario.allCases)
    func configuredColorsStayStableAcrossAppearanceChanges(_ scenario: Scenario) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-10199-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try makeFixture(for: scenario, in: directory)
        let configURL = directory.appendingPathComponent("config", isDirectory: false)
        try fixture.configContents.write(to: configURL, atomically: true, encoding: .utf8)

        let light = try loadSnapshot(configPath: configURL.path, colorScheme: .light)
        let darkAfterFlip = try loadSnapshot(configPath: configURL.path, colorScheme: .dark)
        let lightAfterFlipBack = try loadSnapshot(configPath: configURL.path, colorScheme: .light)

        #expect(light == fixture.light, "light appearance mismatch for \(scenario.rawValue)")
        #expect(darkAfterFlip == fixture.dark, "dark appearance mismatch for \(scenario.rawValue)")
        #expect(lightAfterFlipBack == fixture.light, "flip-back mismatch for \(scenario.rawValue)")
        if fixture.changesWithAppearance {
            #expect(light != darkAfterFlip, "adaptive scenario must switch with appearance")
        } else {
            #expect(light == darkAfterFlip, "terminal colors changed with appearance for \(scenario.rawValue)")
        }
    }

    private func makeFixture(for scenario: Scenario, in directory: URL) throws -> ScenarioFixture {
        let ghosttyDefaults = snapshot(
            foreground: "#FFFFFF",
            background: "#282C34",
            palette: Self.ghosttyDefaultPalette
        )

        switch scenario {
        case .noConfig:
            return ScenarioFixture(
                configContents: "# no Ghostty settings\n",
                light: snapshot(
                    foreground: "#000000",
                    background: "#FEFFFF",
                    cursor: "#98989D",
                    cursorText: "#FFFFFF",
                    selectionBackground: "#ABD8FF",
                    selectionForeground: "#000000",
                    palette: Self.managedLightPalette
                ),
                dark: snapshot(
                    foreground: "#FFFFFF",
                    background: "#1E1E1E",
                    cursor: "#98989D",
                    cursorText: "#FFFFFF",
                    selectionBackground: "#3F638B",
                    selectionForeground: "#FFFFFF",
                    palette: Self.managedDarkPalette
                ),
                changesWithAppearance: true
            )

        case .nonAppearanceSetting:
            return ScenarioFixture(
                configContents: "font-family = Menlo\n",
                light: ghosttyDefaults,
                dark: ghosttyDefaults,
                changesWithAppearance: false
            )

        case .partialExplicitColors:
            var palette = Self.ghosttyDefaultPalette
            palette[1] = "#ABCDEF"
            let expected = snapshot(
                foreground: "#FFFFFF",
                background: "#123456",
                palette: palette
            )
            return ScenarioFixture(
                configContents: "background = #123456\npalette = 1=#abcdef\n",
                light: expected,
                dark: expected,
                changesWithAppearance: false
            )

        case .fullExplicitColors:
            let expected = snapshot(
                foreground: "#FDFDFD",
                background: "#020304",
                palette: Self.fullExplicitPalette
            )
            return ScenarioFixture(
                configContents: themeContents(
                    foreground: expected.foreground,
                    background: expected.background,
                    palette: Self.fullExplicitPalette
                ),
                light: expected,
                dark: expected,
                changesWithAppearance: false
            )

        case .singleTheme:
            let themeURL = directory.appendingPathComponent("single-theme", isDirectory: false)
            let expected = snapshot(
                foreground: "#DDEEFF",
                background: "#102030",
                palette: Self.singleThemePalette
            )
            try themeContents(
                foreground: expected.foreground,
                background: expected.background,
                palette: Self.singleThemePalette
            ).write(to: themeURL, atomically: true, encoding: .utf8)
            return ScenarioFixture(
                configContents: "theme = \(themeURL.path)\n",
                light: expected,
                dark: expected,
                changesWithAppearance: false
            )

        case .conditionalThemePair:
            let lightThemeURL = directory.appendingPathComponent("light-theme", isDirectory: false)
            let darkThemeURL = directory.appendingPathComponent("dark-theme", isDirectory: false)
            let light = snapshot(
                foreground: "#101112",
                background: "#FAFBFC",
                palette: Self.lightThemePalette
            )
            let dark = snapshot(
                foreground: "#F0F1F2",
                background: "#090A0B",
                palette: Self.darkThemePalette
            )
            try themeContents(
                foreground: light.foreground,
                background: light.background,
                palette: Self.lightThemePalette
            ).write(to: lightThemeURL, atomically: true, encoding: .utf8)
            try themeContents(
                foreground: dark.foreground,
                background: dark.background,
                palette: Self.darkThemePalette
            ).write(to: darkThemeURL, atomically: true, encoding: .utf8)
            return ScenarioFixture(
                configContents: "theme = light:\(lightThemeURL.path),dark:\(darkThemeURL.path)\n",
                light: light,
                dark: dark,
                changesWithAppearance: true
            )
        }
    }

    private func loadSnapshot(
        configPath: String,
        colorScheme: GhosttyConfig.ColorSchemePreference
    ) throws -> ColorSnapshot {
        var config = GhosttyConfig()
        config.loadResolvedUserConfig(
            configPaths: [configPath],
            preferredColorScheme: colorScheme,
            adaptiveDefaultThemeEnabled: true,
            environment: [:],
            bundleResourceURL: nil
        )
        let palette = try Dictionary(uniqueKeysWithValues: (0..<16).map { index in
            let color = try #require(config.palette[index], "missing palette index \(index)")
            return (index, color.hexString())
        })
        return ColorSnapshot(
            foreground: config.foregroundColor.hexString(),
            background: config.backgroundColor.hexString(),
            cursor: config.cursorColor.hexString(),
            cursorText: config.cursorTextColor.hexString(),
            selectionBackground: config.selectionBackground.hexString(),
            selectionForeground: config.selectionForeground.hexString(),
            palette: palette
        )
    }

    private func snapshot(
        foreground: String,
        background: String,
        cursor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        palette: [String]
    ) -> ColorSnapshot {
        ColorSnapshot(
            foreground: foreground,
            background: background,
            cursor: cursor ?? foreground,
            cursorText: cursorText ?? background,
            selectionBackground: selectionBackground ?? foreground,
            selectionForeground: selectionForeground ?? background,
            palette: Dictionary(uniqueKeysWithValues: palette.enumerated().map { ($0.offset, $0.element) })
        )
    }

    private func themeContents(
        foreground: String,
        background: String,
        palette: [String]
    ) -> String {
        ([
            "foreground = \(foreground)",
            "background = \(background)",
        ] + palette.enumerated().map { "palette = \($0.offset)=\($0.element)" })
            .joined(separator: "\n") + "\n"
    }
}

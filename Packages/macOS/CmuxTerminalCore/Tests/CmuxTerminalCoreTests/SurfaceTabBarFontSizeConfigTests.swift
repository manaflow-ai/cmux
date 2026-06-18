import Foundation
import Testing
import CmuxFoundation
import CmuxTerminalCore

@Suite
struct SurfaceTabBarFontSizeConfigTests {
    @Test func defaultSurfaceTabBarFontSizeMatchesBaseline() {
        let config = GhosttyConfig()

        #expect(abs(config.surfaceTabBarFontSize - 11) <= 0.0001)
        #expect(abs(config.surfaceTabBarFontSize - GhosttyConfig.defaultSurfaceTabBarFontSize) <= 0.0001)
    }

    @Test func parseSurfaceTabBarFontSizeIntegerValue() {
        var config = GhosttyConfig()

        config.parse("surface-tab-bar-font-size = 14")

        #expect(abs(config.surfaceTabBarFontSize - 14) <= 0.0001)
    }

    @Test func parseSurfaceTabBarFontSizeFractionalValue() {
        var config = GhosttyConfig()

        config.parse("surface-tab-bar-font-size = 12.5")

        #expect(abs(config.surfaceTabBarFontSize - 12.5) <= 0.0001)
    }

    @Test func parseSurfaceTabBarFontSizeClampsBelowMinimum() {
        var config = GhosttyConfig()

        config.parse("surface-tab-bar-font-size = 4")

        #expect(abs(config.surfaceTabBarFontSize - GhosttyConfig.minSurfaceTabBarFontSize) <= 0.0001)
    }

    @Test func parseSurfaceTabBarFontSizeClampsAboveMaximum() {
        var config = GhosttyConfig()

        config.parse("surface-tab-bar-font-size = 48")

        #expect(abs(config.surfaceTabBarFontSize - GhosttyConfig.maxSurfaceTabBarFontSize) <= 0.0001)
    }

    @Test func parseSurfaceTabBarFontSizeIgnoresInvalidAndNonFiniteValues() {
        var config = GhosttyConfig()

        config.parse("surface-tab-bar-font-size = 14")
        config.parse(
            """
            surface-tab-bar-font-size = not-a-number
            surface-tab-bar-font-size = nan
            surface-tab-bar-font-size = inf
            """
        )

        #expect(abs(config.surfaceTabBarFontSize - 14) <= 0.0001)
    }

    @Test func loadUsesParsedSurfaceTabBarFontSizeFromInjectedLoader() {
        let loaded = GhosttyConfig.load(
            preferredColorScheme: .dark,
            useCache: false,
            loadFromDisk: { _ in
                var config = GhosttyConfig()
                config.parse("surface-tab-bar-font-size = 14")
                return config
            }
        )

        #expect(abs(loaded.surfaceTabBarFontSize - 14) <= 0.0001)
    }

    @Test func editorParsesLastSurfaceTabBarValueAndClamps() {
        let contents = """
        surface-tab-bar-font-size = 9
        surface-tab-bar-font-size = 40
        """

        #expect(CmuxGhosttyConfigSettingEditor().parsedSurfaceTabBarFontSize(in: contents)
            == CmuxGhosttyConfigSettingEditor.maxSurfaceTabBarFontSize)
    }

    @Test func editorReturnsNilWhenSurfaceTabBarValueAbsent() {
        #expect(CmuxGhosttyConfigSettingEditor().parsedSurfaceTabBarFontSize(in: "sidebar-font-size = 14") == nil)
    }

    @Test func editorFormatsSurfaceTabBarValueTrimmingTrailingZeros() {
        #expect(CmuxGhosttyConfigSettingEditor().formattedSurfaceTabBarFontSize(12) == "12")
        #expect(CmuxGhosttyConfigSettingEditor().formattedSurfaceTabBarFontSize(12.5) == "12.5")
    }

    @Test func editorWriteSettingRoundTripsSurfaceTabBarValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-tab-bar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.ghostty")
        try "font-size = 13\n".write(to: url, atomically: true, encoding: .utf8)

        try CmuxGhosttyConfigSettingEditor().writeSetting(
            key: CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey,
            value: "13",
            to: url
        )

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("surface-tab-bar-font-size = 13"))
        #expect(contents.contains("font-size = 13"))
        #expect(CmuxGhosttyConfigSettingEditor().parsedSurfaceTabBarFontSize(in: contents) == 13)
    }
}

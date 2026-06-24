import Testing
import CmuxTerminalCore

@Suite
struct SidebarFontSizeConfigTests {
    @Test func defaultSidebarFontSizeMatchesSidebarTitleBaseline() {
        let config = GhosttyConfig()

        #expect(abs(config.sidebarFontSize - 12.5) <= 0.0001)
        #expect(abs(config.sidebarFontSize - GhosttyConfig.defaultSidebarFontSize) <= 0.0001)
    }

    @Test func parseSidebarFontSizeIntegerValue() {
        var config = GhosttyConfig()

        config.parse("sidebar-font-size = 14")

        #expect(abs(config.sidebarFontSize - 14) <= 0.0001)
    }

    @Test func parseSidebarFontSizeFractionalValue() {
        var config = GhosttyConfig()

        config.parse("sidebar-font-size = 13.75")

        #expect(abs(config.sidebarFontSize - 13.75) <= 0.0001)
    }

    @Test func parseSidebarFontSizeClampsBelowMinimum() {
        var config = GhosttyConfig()

        config.parse("sidebar-font-size = 4")

        #expect(abs(config.sidebarFontSize - GhosttyConfig.minSidebarFontSize) <= 0.0001)
    }

    @Test func parseSidebarFontSizeClampsAboveMaximum() {
        var config = GhosttyConfig()

        config.parse("sidebar-font-size = 48")

        #expect(abs(config.sidebarFontSize - GhosttyConfig.maxSidebarFontSize) <= 0.0001)
    }

    @Test func parseSidebarFontSizeIgnoresInvalidAndNonFiniteValues() {
        var config = GhosttyConfig()

        config.parse("sidebar-font-size = 14")
        config.parse(
            """
            sidebar-font-size = not-a-number
            sidebar-font-size = nan
            sidebar-font-size = inf
            """
        )

        #expect(abs(config.sidebarFontSize - 14) <= 0.0001)
    }

    @Test func loadUsesParsedSidebarFontSizeFromInjectedLoader() {
        let loaded = GhosttyConfig.load(
            preferredColorScheme: .dark,
            useCache: false,
            loadFromDisk: { _ in
                var config = GhosttyConfig()
                config.parse("sidebar-font-size = 15")
                return config
            }
        )

        #expect(abs(loaded.sidebarFontSize - 15) <= 0.0001)
    }
}

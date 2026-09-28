import Testing
@testable import CmuxTerminalCore

/// cmux chrome can follow the terminal font, which means it needs the same
/// fallback list Ghostty resolves, not just the last `font-family` line.
@Suite struct GhosttyConfigFontFamiliesTests {
    @Test func collectsFamiliesInFallbackOrder() {
        var config = GhosttyConfig()

        config.parse(
            """
            font-family = "Berkeley Mono"
            font-family = "Symbols Nerd Font Mono"
            """
        )

        #expect(config.fontFamilies == ["Berkeley Mono", "Symbols Nerd Font Mono"])
    }

    @Test func emptyValueResetsTheFallbackList() {
        var config = GhosttyConfig()

        config.parse(
            """
            font-family = "Berkeley Mono"
            font-family = "Symbols Nerd Font Mono"
            font-family = ""
            font-family = "JetBrains Mono"
            """
        )

        #expect(config.fontFamilies == ["JetBrains Mono"])
    }

    @Test func noDirectiveLeavesTheListEmpty() {
        var config = GhosttyConfig()

        config.parse("font-size = 14")

        #expect(config.fontFamilies.isEmpty)
        // The single-family default stays what the terminal has always used.
        #expect(config.fontFamily == "Menlo")
    }

    @Test func primaryFamilyMatchesTheSingleFamilyValue() {
        var config = GhosttyConfig()

        config.parse(
            """
            font-family = "Berkeley Mono"
            font-family = "Symbols Nerd Font Mono"
            """
        )

        #expect(config.fontFamilies.first == "Berkeley Mono")
    }
}

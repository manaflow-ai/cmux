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

    /// The regression this guards: a config with no `font-family` line draws its
    /// terminal in `Menlo`, so chrome that followed the empty list landed on the
    /// monospaced system font and sat beside a Menlo terminal.
    @Test func aConfigWithNoDirectiveStillReportsTheFontTheTerminalDraws() {
        var config = GhosttyConfig()

        config.parse("font-size = 14")

        #expect(config.effectiveFontFamilies == ["Menlo"])
    }

    @Test func configuredFamiliesAreReportedAsTheyAre() {
        var config = GhosttyConfig()

        config.parse("font-family = \"Berkeley Mono\"")

        #expect(config.effectiveFontFamilies == ["Berkeley Mono"])
    }

    /// An explicit `font-family =` means the terminal falls back to its built-in
    /// font, which is not a family this machine can be asked for, so the reset
    /// has to survive into the effective list rather than being refilled.
    @Test func anExplicitResetDoesNotComeBackAsTheDefaultFamily() {
        var config = GhosttyConfig()

        config.parse(
            """
            font-family = "Berkeley Mono"
            font-family = ""
            """
        )

        #expect(config.fontFamilies.isEmpty)
        #expect(config.effectiveFontFamilies == [""])
    }

    /// Ghostty treats a repeated family as one entry in the fallback chain, and
    /// more than one entry is what suppresses cmux's injected CJK fallback, so a
    /// duplicate must not look like a user-authored chain.
    @Test func aRepeatedFamilyIsListedOnce() {
        var config = GhosttyConfig()

        config.parse(
            """
            font-family = "Berkeley Mono"
            font-family = "Symbols Nerd Font Mono"
            font-family = "Berkeley Mono"
            """
        )

        #expect(config.fontFamilies == ["Berkeley Mono", "Symbols Nerd Font Mono"])
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

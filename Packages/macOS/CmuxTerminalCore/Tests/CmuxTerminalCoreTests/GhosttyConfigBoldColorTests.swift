import Testing
@testable import CmuxTerminalCore

@Suite struct GhosttyConfigBoldColorTests {
    @Test func parsesCustomAndBrightBoldColors() {
        var config = GhosttyConfig()

        config.parse("bold-color = #4e2a84")
        #expect(config.boldColor == "#4e2a84")

        config.parse("bold-color = bright")
        #expect(config.boldColor == "bright")
    }

    @Test func ignoresInvalidBoldColor() {
        var config = GhosttyConfig()

        config.parse("bold-color = definitely-not-a-color")

        #expect(config.boldColor == nil)
    }

    @Test func resolvesNamedBoldColor() {
        var config = GhosttyConfig()

        config.parse("bold-color = black")

        #expect(config.boldColor == "#000000")
    }
}

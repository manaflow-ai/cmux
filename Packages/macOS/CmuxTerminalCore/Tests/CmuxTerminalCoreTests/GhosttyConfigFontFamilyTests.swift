import Testing
import CmuxTerminalCore

@Suite
struct GhosttyConfigFontFamilyTests {
    @Test func parserUsesPrimaryFontFamilyAfterReset() {
        var config = GhosttyConfig()

        config.parse(
            """
            font-family = Old Mono
            font-family =
            font-family = JetBrains Mono
            font-family = Hiragino Sans
            """
        )

        #expect(config.fontFamily == "JetBrains Mono")
    }
}

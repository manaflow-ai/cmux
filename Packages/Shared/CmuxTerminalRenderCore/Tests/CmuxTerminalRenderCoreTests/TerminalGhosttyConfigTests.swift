import CmuxTerminalRenderCore
import CmuxTheme
import Testing

@Suite struct TerminalGhosttyConfigTests {
    private func lines(_ config: TerminalGhosttyConfig) -> [String] {
        config.text.split(separator: "\n").map(String.init)
    }

    @Test func defaultsCarryTheScrollbackBudget() {
        let lines = lines(TerminalGhosttyConfig())
        #expect(lines.contains("scrollback-limit-bytes = 8388608"))
        #expect(lines.contains("font-size = 13"))
        #expect(lines.contains("background-opacity = 1"))
        #expect(!lines.contains { $0.hasPrefix("background =") })
    }

    @Test func fractionalFontSize() {
        #expect(lines(TerminalGhosttyConfig(fontSize: 17.5)).contains("font-size = 17.5"))
    }

    @Test func themeBecomesGhosttyColors() {
        let theme = ThemeInput(background: ThemeRGB(hex: 0x101010), foreground: ThemeRGB(hex: 0xE0E0E0),
                               palette: ThemeInput.ghosttyDefault.palette,
                               selectionBackground: ThemeRGB(hex: 0x333333))
        let lines = lines(TerminalGhosttyConfig(theme: theme))
        #expect(lines.contains("background = #101010"))
        #expect(lines.contains("foreground = #E0E0E0"))
        #expect(lines.contains("palette = 0=#1D1F21"))
        #expect(lines.contains("palette = 15=#EAEAEA"))
        #expect(lines.filter { $0.hasPrefix("palette = ") }.count == 16)
        #expect(lines.contains("selection-background = #333333"))
        #expect(lines.contains { $0.hasPrefix("cursor-color = #") })
    }

    @Test func selectionFallsBackToTheTokenMixNotAnAccent() throws {
        let theme = ThemeInput(background: ThemeRGB(hex: 0x000000), foreground: ThemeRGB(hex: 0xFFFFFF))
        let line = try #require(lines(TerminalGhosttyConfig(theme: theme)).first { $0.hasPrefix("selection-background") })
        let hex = String(line.dropFirst("selection-background = #".count))
        // A gray: equal channels (fg mixed into bg), never a hue.
        #expect(hex.count == 6)
        #expect(hex.prefix(2) == hex.dropFirst(2).prefix(2) && hex.prefix(2) == hex.suffix(2))
    }

    @Test func translucentThemeStillDrawsOpaque() {
        let theme = ThemeInput(background: ThemeRGB(hex: 0x202020), foreground: ThemeRGB(hex: 0xFFFFFF), backgroundOpacity: 0.5)
        let lines = lines(TerminalGhosttyConfig(theme: theme))
        #expect(lines.contains("background-opacity = 1"))
        #expect(lines.contains("background = #202020"))
    }
}

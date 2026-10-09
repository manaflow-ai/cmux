import CmuxTerminalRenderCore
import Testing

@Suite struct TerminalAppearanceConfigTests {
    private func lines(_ config: TerminalGhosttyConfig) -> [String] {
        config.text.split(separator: "\n").map(String.init)
    }

    @Test func defaultsEmitNoFontFamilyOrCursorStyle() {
        let lines = lines(TerminalGhosttyConfig())
        #expect(!lines.contains { $0.hasPrefix("font-family") })
        #expect(!lines.contains { $0.hasPrefix("cursor-style =") })
    }

    @Test func fontFamilyAndCursorStyleBecomeGhosttyKeys() {
        let lines = lines(TerminalGhosttyConfig(cursorBlink: true, fontFamily: " Menlo ", cursorStyle: .bar))
        #expect(lines.contains("font-family = Menlo"))
        #expect(lines.contains("cursor-style = bar"))
        #expect(lines.contains("cursor-style-blink = true"))
    }

    @Test func blankOrMultilineFamilyIsIgnored() {
        #expect(TerminalGhosttyConfig(fontFamily: "  ").fontFamily == nil)
        let lines = lines(TerminalGhosttyConfig(fontFamily: "Menlo\nfont-size = 99"))
        #expect(!lines.contains { $0.hasPrefix("font-family") })
        #expect(lines.filter { $0.hasPrefix("font-size") } == ["font-size = 13"])
    }

    @Test func appearanceClampsTheBaseSize() {
        let sizing = TerminalAppearance(baseFontSize: 100).fontSizing()
        #expect(sizing.baseSize == TerminalFontSizing().maximumSize)
        #expect(TerminalAppearance(baseFontSize: 16).fontSizing().baseSize == 16)
    }
}

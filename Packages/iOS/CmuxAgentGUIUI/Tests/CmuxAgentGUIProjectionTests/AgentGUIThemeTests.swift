import CMUXMobileCore
import CmuxAgentGUIProjection
import Testing

@Suite
struct AgentGUIThemeTests {
    @Test
    func derivesExactSRGBMixes() {
        let theme = AgentGUITheme(terminalTheme: terminalTheme(background: "#000000", foreground: "#ffffff"))

        expect(theme.dimForeground, equals: 0.60)
        expect(theme.faintForeground, equals: 0.40)
        expect(theme.raisedBackground, equals: 0.05)
        expect(theme.inputBackground, equals: 0.08)
        expect(theme.hoverBackground, equals: 0.12)
        expect(theme.border, equals: 0.15)
    }

    @Test
    func accentUsesDeclaredANSIScanOrder() {
        var palette = Array(repeating: "#ff0000", count: TerminalTheme.paletteCount)
        palette[12] = "#0000ff"
        palette[4] = "#00aacc"
        let theme = AgentGUITheme(terminalTheme: terminalTheme(palette: palette))

        #expect(theme.accent == AgentGUIRGBColor(hex: "#00aacc"))
    }

    @Test
    func accentRejectsLowSaturationAndFallsBackToForeground() {
        let theme = AgentGUITheme(terminalTheme: terminalTheme(
            foreground: "#123456",
            palette: Array(repeating: "#777777", count: TerminalTheme.paletteCount)
        ))

        #expect(theme.accent == AgentGUIRGBColor(hex: "#123456"))
    }

    @Test
    func errorUsesNormalANSIRedBeforeBrightRed() {
        var palette = Array(repeating: "#777777", count: TerminalTheme.paletteCount)
        palette[1] = "#aa1122"
        palette[9] = "#ff3344"
        let theme = AgentGUITheme(terminalTheme: terminalTheme(palette: palette))

        #expect(theme.error == AgentGUIRGBColor(hex: "#aa1122"))
    }

    @Test
    func invalidThemeFallsBackAsOneCompletePalette() {
        let invalid = TerminalTheme(
            background: "bad",
            foreground: "#ffffff",
            cursor: "#ffffff",
            selectionBackground: "#000000",
            selectionForeground: "#ffffff",
            palette: []
        )

        #expect(AgentGUITheme(terminalTheme: invalid) == AgentGUITheme(terminalTheme: .monokai))
    }

    private func terminalTheme(
        background: String = "#101014",
        foreground: String = "#e8e8ec",
        palette: [String] = TerminalTheme.monokai.palette
    ) -> TerminalTheme {
        TerminalTheme(
            background: background,
            foreground: foreground,
            cursor: foreground,
            selectionBackground: background,
            selectionForeground: foreground,
            palette: palette
        )
    }

    private func expect(_ color: AgentGUIRGBColor, equals component: Double) {
        #expect(abs(color.red - component) < 0.000_001)
        #expect(abs(color.green - component) < 0.000_001)
        #expect(abs(color.blue - component) < 0.000_001)
    }
}

import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneThemeTests {
    @Test func coversEveryKeyThePageMapsToACSSVariable() {
        let keys = Set(AgentPaneTheme.values(.fallback).keys)
        #expect(keys == ["isDark", "pageBackground", "surfaceBackground", "surfaceElevatedBackground", "inputBackground", "border",
                         "borderStrong", "text", "mutedText", "softText", "accent", "accentSoft", "accentText", "danger", "shadow"])
    }

    @Test func writesCSSColors() {
        #expect(AgentPaneTheme.css(ThemeRGB(hex: 0x102030)) == "rgba(16, 32, 48, 1.0)")
        #expect(AgentPaneTheme.css(ThemeRGB(hex: 0xFFFFFF, alpha: 0.25)) == "rgba(255, 255, 255, 0.25)")
    }

    /// No blue accent (REWRITE.md visual rules): the accent is the foreground.
    @Test func theAccentIsTheForeground() {
        let values = AgentPaneTheme.values(.fallback)
        #expect(values["accent"] as? String == values["text"] as? String)
    }

    /// The accent is the foreground, so a button filled with it needs the
    /// background for its label: white on a light-on-dark accent vanished.
    /// Opaque, since a translucent window's page background shows through.
    @Test func buttonLabelsOnTheAccentUseTheOpaqueBackground() {
        let light = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F)))
        let translucent = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4), backgroundOpacity: 0.8))
        for tokens in [ThemeTokens.fallback, light, translucent] {
            let values = AgentPaneTheme.values(tokens)
            var opaque = tokens.contentBackground
            opaque.alpha = 1
            #expect(values["accentText"] as? String == AgentPaneTheme.css(opaque))
        }
    }
}

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

    /// With background-opacity below 1 the window's backdrop shows through
    /// the terminal; the pane, its composer and the composer's field must let
    /// it through too, while text and labels on the accent stay opaque. The
    /// field was composited to an opaque color, a solid block over the blur.
    @Test func aTranslucentThemeKeepsThePageTranslucentAndItsTextOpaque() {
        let translucent = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4), backgroundOpacity: 0.8))
        let values = AgentPaneTheme.values(translucent)
        for key in ["pageBackground", "surfaceBackground", "inputBackground"] {
            let css = values[key] as? String ?? ""
            #expect(css.hasSuffix(", 0.8)"), "\(key) is \(css)")
        }
        for key in ["text", "accent", "accentText"] {
            let css = values[key] as? String ?? ""
            #expect(css.hasSuffix(", 1.0)"), "\(key) is \(css)")
        }
        // An opaque theme keeps its opaque field.
        let opaqueField = AgentPaneTheme.values(.fallback)["inputBackground"] as? String ?? ""
        #expect(opaqueField.hasSuffix(", 1.0)"))
    }
}

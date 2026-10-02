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

    /// In a translucent window the window root paints the one translucent
    /// sheet (`WindowBackdrop`) and every layer above it stays clear, so the
    /// terminal shows the background at the configured opacity once. The
    /// page must too: its own copy of the color over the sheet (0.8 over 0.8
    /// is 0.96) is a near-solid block over the blur. The field adds only a
    /// faint tint; text and labels on the accent stay opaque. A macOS glass
    /// style makes the window non-opaque even at opacity 1.
    @Test(arguments: [(0.8, 20), (1.0, -1)])
    func aTranslucentWindowsPaneLetsAsMuchThroughAsTheTerminal(opacity: Double, blur: Int) throws {
        let tokens = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E2E), foreground: ThemeRGB(hex: 0xCDD6F4),
                                                         backgroundOpacity: opacity, backgroundBlur: blur))
        #expect(!WindowBackdrop(tokens).panesPaintBackground)
        let values = AgentPaneTheme.values(tokens)
        for key in ["pageBackground", "surfaceBackground"] {
            #expect(Self.rgba(values[key])?.alpha == 0, "\(key) is \(values[key] ?? "nil")")
        }
        let sheet = tokens.backgroundOpacity
        let field = try #require(Self.rgba(values["inputBackground"]))
        let fieldOverSheet = sheet + field.alpha * (1 - sheet)
        #expect(fieldOverSheet < sheet + 0.05, "the field over the sheet lets through \(1 - fieldOverSheet)")
        for key in ["text", "accent", "accentText"] {
            #expect(Self.rgba(values[key])?.alpha == 1, "\(key) is \(values[key] ?? "nil")")
        }
        #expect(AgentPaneTheme.underPageColor(tokens).alpha == 0)
    }

    /// An opaque window's panes paint the background, and so does the page.
    @Test func anOpaqueWindowsPagePaintsTheBackground() {
        let values = AgentPaneTheme.values(.fallback)
        #expect(values["pageBackground"] as? String == AgentPaneTheme.css(ThemeTokens.fallback.contentBackground))
        #expect(AgentPaneTheme.underPageColor(.fallback) == ThemeTokens.fallback.contentBackground)
    }

    /// An opaque theme looks as it did: the field's tint over the page is the
    /// color the field used to be painted with.
    @Test func anOpaqueThemesFieldLooksTheSame() throws {
        let tokens = ThemeTokens.fallback
        let values = AgentPaneTheme.values(tokens)
        let field = try #require(Self.rgba(values["inputBackground"]))
        let shown = field.composited(over: tokens.contentBackground)
        let before = tokens.hoverFill.composited(over: tokens.contentBackground)
        #expect(abs(shown.red - before.red) < 0.005 && abs(shown.green - before.green) < 0.005 && abs(shown.blue - before.blue) < 0.005)
    }

    /// `rgba(r, g, b, a)` as the page receives it.
    private static func rgba(_ value: (any Sendable)?) -> ThemeRGB? {
        guard let text = value as? String, text.hasPrefix("rgba("), text.hasSuffix(")") else { return nil }
        let parts = text.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return ThemeRGB(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts[3])
    }
}

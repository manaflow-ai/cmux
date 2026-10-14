import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// hq#1957 (Leo and Lawrence 2026-10-14): the composer strip's look is a Debug Settings choice the
/// page gets through the theme (`composerStrip`, which the page puts on its root as
/// `data-composer-strip`). It stays off until Leo picks a look.
@Suite
struct AgentPaneComposerStripTests {
    private static let tokens = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6)))

    @Test func theTunableDefaultsToOffAndOffersEveryLook() {
        #expect(AgentPaneTunables.composerStrip.defaultValue == .off)
        #expect(AgentPaneTunables.composerStrip.key == "agentPane.composerStrip")
        #expect(AgentPaneComposerStrip.allCases.map(\.rawValue) == ["off", "flat", "tab", "gooey", "tray"])
        #expect(AgentPaneTunables.all.contains { $0.key == "agentPane.composerStrip" })
    }

    @Test(arguments: AgentPaneComposerStrip.allCases)
    func theThemeCarriesTheChosenLook(_ look: AgentPaneComposerStrip) {
        let values = AgentPaneTheme.values(Self.tokens, composerStrip: look)
        #expect(values["composerStrip"] as? String == look.rawValue)
    }

    @Test func theThemeCarriesTheTunablesValueByDefault() {
        let values = AgentPaneTheme.values(Self.tokens)
        #expect(values["composerStrip"] as? String == AgentPaneTunables.composerStrip.value.rawValue)
    }
}

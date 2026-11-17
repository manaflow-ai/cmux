import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Pages round every button as a tab (Lawrence 2026-11-12: "roundness of all buttons should match
/// roundness of tabs/workspaces"): the host hands them the one button corner as `--cmux-button-radius`,
/// which `--ds-radius-control` reads, in CSS px of the page's zoom.
@MainActor @Suite(.serialized) struct WebThemeButtonRadiusTests {
    @Test(arguments: Density.allCases)
    func pagesReadTheTabCorner(density: Density) {
        let saved = DesignSettings.shared.density
        defer { DesignSettings.shared.density = saved }
        DesignSettings.shared.density = density
        let input = ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0))
        let css = WebTheme(ThemeTokens.derive(from: input)).variables["--cmux-button-radius"]
        let expected = SidebarCardMetrics.px(Metrics.tabCornerRadius / max(DesignSettings.shared.uiScale, 0.01))
        #expect(css == expected, "\(density): pages read \(String(describing: css)), a tab is \(expected)")
    }
}

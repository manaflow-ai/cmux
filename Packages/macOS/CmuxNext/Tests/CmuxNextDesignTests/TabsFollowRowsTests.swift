@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// Tabs follow the workspace rows (Lawrence 2026-11-11; the rows are the reference, #39984): at every density a tab
/// pill is the density's one-line row, and at Default it takes the row's Codex corner (10 on 30).
@MainActor @Suite(.serialized) struct TabsFollowRowsTests {
    @Test(arguments: DensityPreset.allCases)
    func aTabIsTheDensitysRow(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        guard Metrics.tabsFollowRows else { return }
        let row = SidebarRowTokens(density: .compact, textSize: .standard, base: SidebarRowTokens.current.base).listRowHeight
        #expect(Metrics.tabHeight == row, "\(preset): the tab is \(Metrics.tabHeight), the row \(row)")
        #expect(Metrics.tabStripHeight - Metrics.tabHeight == MetricTunables.tabStripHeight.value - MetricTunables.tabHeight.value,
                "\(preset): the room around the pill is the density's")
        if preset == .cozy { #expect(Metrics.tabCornerRadius == 10) }
    }
}

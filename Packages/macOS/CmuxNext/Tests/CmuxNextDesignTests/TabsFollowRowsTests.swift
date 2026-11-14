@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// Tabs follow the workspace rows (Lawrence 2026-11-11; the rows are the reference, #39984): at every density a tab
/// pill is the density's one-line row, with Chrome's tab corner (8 on 30).
@MainActor @Suite(.serialized) struct TabsFollowRowsTests {
    @Test(arguments: DensityPreset.allCases)
    func aTabIsTheDensitysRow(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        let row = SidebarRowTokens(density: .compact, textSize: .standard, base: SidebarRowTokens.current.base).listRowHeight
        #expect(Metrics.tabHeight == row, "\(preset): the tab is \(Metrics.tabHeight), the row \(row)")
        // Compact and Default set their strip (26 and 36 pt, 3 pt around the pill; Lucas 2026-11-13); the others keep
        // the density's room around a row-tall pill.
        if Metrics.tabsFollowRows {
            #expect(Metrics.tabStripHeight - Metrics.tabHeight == MetricTunables.tabStripHeight.value - MetricTunables.tabHeight.value,
                    "\(preset): the room around the pill is the density's")
        } else {
            #expect(Metrics.tabStripHeight - Metrics.tabHeight == 6, "\(preset): 3 pt above and below the pill")
        }
        // Chrome's tab corner, 8 on 30, at every density (Lawrence 2026-11-11).
        #expect(Metrics.tabCornerRadius == Metrics.chromeRowCornerRadius(height: Metrics.tabHeight))
    }

    /// A density that sets its strip (Compact 26) still fits a taller row: a roomier sidebar density and larger
    /// sidebar text make the row taller than the density's, and the strip grows by as much (Codex review, #42393).
    @Test(arguments: [DensityPreset.ultraCompact, .compact, .cozy])
    func aSetStripGrowsWithATallerRow(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize)
        defer { (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize) = saved }
        design.densityTokens = preset.tokens
        let room = Metrics.tabStripHeight - Metrics.tabHeight
        design.sidebarSections.density = .comfortable
        design.sidebarSections.textSize = .larger
        #expect(Metrics.tabHeight > Metrics.densityRowHeight, "\(preset): the row grows")
        #expect(Metrics.tabStripHeight - Metrics.tabHeight == room, "\(preset): the strip keeps its room around the pill")
    }
}

@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// Tabs follow the workspace rows (Lawrence 2026-11-11; the rows are the reference, #39984), except where a density sets
/// its browser row (Lawrence 2026-11-13: Helium's 28 pt row at Default, 20 at Compact, Chrome's 34 at Spacious): there
/// the pill is that row with the density's one gap above and below it. The corner is the row's share of Helium's 8 on 28.
@MainActor @Suite(.serialized) struct TabsFollowRowsTests {
    @Test(arguments: DensityPreset.allCases)
    func aTabIsTheDensitysRow(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        let sidebarRow = SidebarRowTokens(density: .compact, textSize: .standard, base: SidebarRowTokens.current.base).listRowHeight
        let browserRow = preset.tokens.tokens["browserRowHeight"].map { CGFloat($0) }
        let row = browserRow ?? sidebarRow
        #expect(Metrics.tabHeight == row, "\(preset): the tab is \(Metrics.tabHeight), the row \(row)")
        if browserRow != nil {
            #expect(Metrics.tabStripHeight - Metrics.tabHeight == 2 * (Metrics.browserRowGap ?? 0), "\(preset): one gap above and below the pill")
        } else if Metrics.tabsFollowRows {
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

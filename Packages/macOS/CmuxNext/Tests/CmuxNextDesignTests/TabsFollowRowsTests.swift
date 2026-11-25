@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// Tabs follow the workspace rows at every density (Lawrence 2026-11-11; Lucas 2026-11-14: sidebar rows and tabs one
/// height and one text size): Helium's and Chrome's 30 pt vertical tab row at Default and Comfortable.
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
        // The strip padding above and below the tab: the density's own `browserRowGap`, else Default's
        // 3 pt times the density's factor.
        let gap = preset.tokens.tokens["browserRowGap"].map { CGFloat($0) * 2 } ?? (3 * CGFloat(preset.scaleFactor) * 2).rounded()
        #expect(Metrics.tabStripHeight - Metrics.tabHeight == gap, "\(preset): the strip is \(Metrics.tabStripHeight), the tab \(Metrics.tabHeight)")
        #expect(Metrics.tabCornerRadius == (9 * CGFloat(preset.scaleFactor) * 2).rounded() / 2)
    }

    /// A tab is a list row's height at every sidebar density and text size, not only the defaults: Default's 29 pt row
    /// is its 27 pt list row with the fill only the sidebar's Compact density draws (Codex review).
    @Test(arguments: DensityPreset.allCases)
    func aTabIsAListRowAtEverySidebarSetting(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize)
        defer { (design.densityTokens, design.sidebarSections.density, design.sidebarSections.textSize) = saved }
        design.densityTokens = preset.tokens
        for density in SidebarDensity.allCases {
            for textSize in SidebarTextSize.allCases {
                design.sidebarSections.density = density
                design.sidebarSections.textSize = textSize
                let row = SidebarRowTokens.current.listRowHeight
                #expect(Metrics.tabHeight == row, "\(preset) \(density)/\(textSize): the tab is \(Metrics.tabHeight), the row \(row)")
            }
        }
    }

    /// A density that sets its strip (Compact 26) still fits a taller row: a roomier sidebar density and larger
    /// sidebar text make the row taller than the density's, and the strip grows by as much (Codex review, #42393).
    @Test(arguments: [DensityPreset.ultraCompact, .compact])
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

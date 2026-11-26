import CoreGraphics
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// Lucas 2026-11-24 (screenshot, a line down the left edge): the red traffic light started at 14 pt, Home's house at
/// 12.5, a globe at 13 and a text-only title at 13. Then, on zoomed shots at Default, Ultra-compact and Spacious: the
/// whole row moves, not only the glyph, so the house centers under the light. Every row's first glyph and text-only title
/// start where the house does: the fill moves (`SidebarRowTuning.outerInset`), and the content inset inside it stays
/// the tab's icon inset.
@MainActor @Suite(.serialized) struct SidebarRowsStartOnTrafficLightsTests {
    @Test(arguments: DensityPreset.allCases)
    func homesHouseCentersUnderTheRedLight(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        let lightCenter = TrafficLightsLine.defaultLeadingX(scale: 2) + TrafficLightsLine.buttonSide / 2
        let content = SidebarStyle.horizontalInset + SidebarStyle.contentInset
        let houseCenter = content + SidebarStyle.homeGlyphInkWidth / 2
        // The content starts on the 2x pixel grid, so the centers differ by at most half a pixel.
        #expect(abs(houseCenter - lightCenter) <= 0.25 + 0.001,
                "\(preset): the house centers at \(houseCenter), the red light at \(lightCenter)")
        #expect(abs((content * 2).rounded() - content * 2) < 0.001, "\(preset): the content starts off the pixel grid")
        #expect(SidebarStyle.horizontalInset > 0, "\(preset): the fill touches the sidebar's edge")
    }

    /// A custom density that sets `sidebarRowInset` keeps its own fill inset.
    @Test func aCustomDensitysRowInsetWins() throws {
        var mine = CustomDensitiesSetting.duplicate(DensityPreset.cozy.tokens, name: "Wide Fill", existing: [])
        mine = DensityTokenCatalog.setting(try #require(DensityTokenCatalog.entry("sidebarRowInset")), to: 10, in: mine)
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = mine
        #expect(SidebarStyle.horizontalInset == 10)
    }
}

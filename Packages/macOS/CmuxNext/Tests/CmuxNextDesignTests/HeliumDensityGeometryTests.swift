@testable import CmuxNextDesign
import CoreGraphics
import Testing

/// Chrome keeps Default's proportions and the specified row heights.
@MainActor @Suite(.serialized) struct HeliumDensityGeometryTests {
    /// Rows keep the owner's heights; gaps, bars and titles scale together.
    struct Expected: Sendable, CustomTestStringConvertible {
        let preset: DensityPreset
        let row: CGFloat
        let gap: CGFloat
        let omnibar: CGFloat
        let title: CGFloat
        var testDescription: String { "\(preset.rawValue): \(row) pt rows, \(gap) pt gaps" }
    }

    nonisolated static let cases: [Expected] = zip(DensityPreset.allCases, [24.0, 28, 30, 32, 36]).map { preset, row in
        Expected(preset: preset, row: row, gap: (3 * preset.scaleFactor * 2).rounded() / 2,
                 omnibar: (29 * preset.scaleFactor * 2).rounded() / 2, title: 14 * preset.scaleFactor)
    }

    private func withDensity(_ preset: DensityPreset, _ body: () -> Void) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        body()
    }

    /// The tab pill is the density's chrome row, a sidebar row's height; the toolbar buttons are the omnibar's.
    @Test(arguments: cases)
    func theTabPillIsTheDensitysRow(_ expected: Expected) {
        withDensity(expected.preset) {
            #expect(Metrics.tabHeight == expected.row, "tab \(Metrics.tabHeight)")
            #expect(Metrics.chromeRowHeight == expected.row, "chrome row \(Metrics.chromeRowHeight)")
            #expect(expected.preset.tokens.toolbarButtonSize == expected.omnibar, "toolbar button \(expected.preset.tokens.toolbarButtonSize)")
        }
    }

    /// One gap above the pills and under them, with or without the pane padding above the strip.
    @Test(arguments: cases)
    func oneGapAboveAndBelowThePills(_ expected: Expected) {
        withDensity(expected.preset) {
            let chrome = PaneChromeMetrics.current
            #expect(Metrics.stripTopOutset + chrome.pillTop(scale: 2) == expected.gap, "above the pill")
            #expect(chrome.tabGap(scale: 2) == expected.gap, "under the pill")
            #expect(chrome.resolvedStripHeight(scale: 2) == expected.row + 2 * expected.gap - Metrics.stripTopOutset,
                    "strip \(chrome.resolvedStripHeight(scale: 2))")
        }
    }

    /// Corners scale from Default independently of the row height exceptions.
    @Test(arguments: cases)
    func tabsRoundAsHeliumsOnTheRow(_ expected: Expected) {
        withDensity(expected.preset) {
            let corner = (9 * CGFloat(expected.preset.scaleFactor) * 2).rounded() / 2
            #expect(Metrics.tabCornerRadius == corner, "tab corner \(Metrics.tabCornerRadius)")
        }
    }

    /// Every title scales from Default's 14 pt size.
    @Test(arguments: cases)
    func tabTitlesAreTheDensitysSize(_ expected: Expected) {
        withDensity(expected.preset) {
            #expect(abs(Typography.tabTitle.pointSize - expected.title) < 0.0001, "tab title \(Typography.tabTitle.pointSize)")
        }
    }
}

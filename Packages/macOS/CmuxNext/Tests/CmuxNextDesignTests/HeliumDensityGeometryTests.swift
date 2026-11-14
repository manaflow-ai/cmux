@testable import CmuxNextDesign
import CoreGraphics
import Testing

/// The browser pane's tab bar and omnibar take Helium's geometry at Default, a proportionally smaller copy at
/// Compact (20 pt rows) and Chrome's sizes with Helium's shapes at Spacious (Lawrence 2026-11-13, density thread:
/// "Helium is nearly pixel perfect", "use helium for default, for spacious, still keep helium details, but match
/// chrome's sizing/padding").
///
/// Measured from 2x captures of Helium 0.21.3.1 and Chrome 157 on cmux-lawrence-2 and read from their source
/// (plans/cmux-next/spec-proposals/visuals/design-tokens.md, "Browser chrome: Helium and Chrome source values"):
/// Helium draws a 28 pt tab pill 3 pt below the window top, its toolbar's 28 pt omnibar 3 pt below the pill and
/// 3 pt above the page (`kTabHeight` 31 less `kTabStripPadding` 3, `kLocationBarHeight` 28, `TOOLBAR_INTERIOR_MARGIN`
/// 3), both rounded 8 pt. Chrome draws 34 pt rows 6 pt apart (`kTabHeight` 34 + 6 above, `kLocationBarHeight` 34,
/// `TOOLBAR_INTERIOR_MARGIN` 6).
@MainActor @Suite(.serialized) struct HeliumDensityGeometryTests {
    /// One density's browser chrome: the row a tab pill and the omnibar share, and the one gap above the pills,
    /// between the pills and the omnibar, and under the omnibar.
    struct Expected: Sendable, CustomTestStringConvertible {
        let preset: DensityPreset
        let row: CGFloat
        let gap: CGFloat
        var testDescription: String { "\(preset.rawValue): \(row) pt rows, \(gap) pt gaps" }
    }

    nonisolated static let cases: [Expected] = [
        Expected(preset: .compact, row: 20, gap: 2),
        Expected(preset: .cozy, row: 28, gap: 3),
        Expected(preset: .comfortable, row: 31, gap: 4),
        Expected(preset: .spacious, row: 34, gap: 6),
    ]

    private func withDensity(_ preset: DensityPreset, _ body: () -> Void) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        body()
    }

    /// The tab pill is the density's browser row, Helium's 28 pt at Default (not the sidebar's 30 pt Codex fill).
    @Test(arguments: cases)
    func theTabPillIsTheDensitysBrowserRow(_ expected: Expected) {
        withDensity(expected.preset) {
            #expect(Metrics.tabHeight == expected.row, "tab \(Metrics.tabHeight)")
            #expect(Metrics.chromeRowHeight == expected.row, "chrome row \(Metrics.chromeRowHeight)")
            #expect(expected.preset.tokens.toolbarButtonSize == expected.row, "toolbar button \(expected.preset.tokens.toolbarButtonSize)")
        }
    }

    /// One gap above the pills and under them (the omnibar's top), as Helium's 3 pt at Default, with or without the
    /// pane padding above the strip (the flush corner has none).
    @Test(arguments: cases)
    func oneGapAboveAndBelowThePills(_ expected: Expected) {
        withDensity(expected.preset) {
            let chrome = PaneChromeMetrics.current
            #expect(Metrics.stripTopOutset + chrome.pillTop(scale: 2) == expected.gap, "above the pill")
            #expect(chrome.tabGap(scale: 2) == expected.gap, "under the pill")
            // The strip holds the gap above the pill less the pane padding over it (none under the flush corner), the pill and
            // the gap under it.
            #expect(chrome.resolvedStripHeight(scale: 2) == expected.row + 2 * expected.gap - Metrics.stripTopOutset,
                    "strip \(chrome.resolvedStripHeight(scale: 2))")
            // The top chrome a browser pane draws above its page: gap, pill, gap, omnibar, gap. Helium's is 65 pt.
            let total = Metrics.stripTopOutset + chrome.resolvedStripHeight(scale: 2) + expected.row + chrome.tabGap(scale: 2)
            #expect(total == 3 * expected.gap + 2 * expected.row, "top chrome \(total)")
        }
    }

    /// Helium's 8 pt corner on its 28 pt tab and omnibar, the same share of the row at every density
    /// (6 on 20, 9 on 31, 10 on 34).
    @Test(arguments: cases)
    func tabsRoundAsHeliumsOnTheRow(_ expected: Expected) {
        withDensity(expected.preset) {
            let corner = (expected.row * 8 / 28).rounded()
            #expect(Metrics.chromeRowCornerRadius(height: expected.row) == corner)
            #expect(Metrics.tabCornerRadius == corner, "tab corner \(Metrics.tabCornerRadius)")
        }
    }
}

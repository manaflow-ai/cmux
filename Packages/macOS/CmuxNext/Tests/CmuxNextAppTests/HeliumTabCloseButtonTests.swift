import CmuxNextDesign
@testable import CmuxNextTabs
import CoreGraphics
import Testing

/// A tab's x is Helium's, point for point (Lawrence msg 48706: "color + shape + size + roundness etc must all match";
/// 2026-11-28: "both size and icon size etc must perfectly match helium").
///
/// Helium (imputnet/helium tabs.patch, tab_close_button.cc, layout-constants.patch; rounded icons on): a 14 pt icon and
/// visible square (`kTabCloseButtonSize`); close_weight500_custom's ink, 13.42 of 24 units with a 2.25 unit stroke; a
/// `RoundRectHighlightPathGenerator` plate with a 4 pt corner. At its Default density (28 pt tab) the plate is the 14 pt
/// square, 6 pt inside the tab's end; at Spacious (32 pt tab) it is the 26 pt button less `Insets(1)`, 24 pt, around the
/// square 8 pt inside the end. cmux draws Default's x on tabs under 32 pt and Spacious's from 32 pt.
@MainActor @Suite(.serialized) struct HeliumTabCloseButtonTests {
    nonisolated static let presets = DensityPreset.allCases

    private func withDensity(_ preset: DensityPreset, _ body: (TabStripMetrics, CGFloat) -> Void) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        body(TabStripMetrics.standard, Metrics.tabHeight)
    }

    /// Helium's numbers at every density: the square, icon, ink, stroke and corner never scale; the plate and the end
    /// inset are Default's below a 32 pt tab and Spacious's from it.
    @Test(arguments: presets)
    func theXIsHeliumsInPoints(_ preset: DensityPreset) {
        withDensity(preset) { m, row in
            let spacious = row >= 32
            #expect(m.closeButtonSize == 14, "\(preset): square \(m.closeButtonSize)")
            #expect(m.closePlateSide == (spacious ? 24 : 14), "\(preset): plate \(m.closePlateSide) on a \(row) pt tab")
            #expect(m.closeCornerRadius == 4, "\(preset): corner \(m.closeCornerRadius)")
            #expect(m.contentTrailingInset == (spacious ? 8 : 6), "\(preset): square \(m.contentTrailingInset) pt from the end")
            #expect(abs(m.closeGlyphInk - 14 * 13.42 / 24) < 0.0001, "\(preset): ink \(m.closeGlyphInk)")
            #expect(abs(m.closeGlyphLineWidth - 14 * 2.25 / 24) < 0.0001, "\(preset): stroke \(m.closeGlyphLineWidth)")
        }
    }

    /// Default (Helium's Default x): the 14 pt square with a 4 pt corner, its end 6 pt inside the pill's.
    @Test func theDefaultX() {
        withDensity(.cozy) { m, row in
            #expect(row < 32)
            #expect(m.closePlateSide == 14 && m.closeCornerRadius == 4 && m.contentTrailingInset == 6)
        }
    }

    /// The click target keeps Apple's 20 x 20 pt minimum around the x.
    @Test(arguments: presets)
    func theClickTargetStaysTwentyPoints(_ preset: DensityPreset) {
        withDensity(preset) { m, _ in
            let drawn = CGRect(x: 100, y: 5, width: m.closeButtonSize, height: m.closeButtonSize)
            let hit = m.closeHitRect(drawn)
            #expect(hit.width >= 20 && hit.height >= 20, "\(preset): hit \(hit.size)")
            #expect(hit.midX == drawn.midX && hit.midY == drawn.midY)
        }
    }
}

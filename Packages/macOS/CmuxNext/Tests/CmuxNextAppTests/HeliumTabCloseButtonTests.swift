import CmuxNextDesign
@testable import CmuxNextTabs
import CoreGraphics
import Testing

/// A tab's x is Helium's at every density, scaled with the row (Lawrence 2026-11-13: "need to match the X icon on
/// helium in terms of hover too (like roundness of it), should be applied to all densities").
///
/// Helium 0.21.3.1 at its 28 pt tab, measured from 2x captures on cmux-lawrence-2 (refs in
/// plans/cmux-next/helium-density/): the hover square is 14 pt with a 4 pt corner (tab_close_button.cc's
/// `RoundRectHighlightPathGenerator` radius, not concentric with the pill), its right edge 6 pt inside the pill,
/// and the x's ink is 8 pt square. The same shares of the row at Compact (20), Comfortable (31) and Spacious (34).
@MainActor @Suite(.serialized) struct HeliumTabCloseButtonTests {
    nonisolated static let presets: [DensityPreset] = [.compact, .cozy, .comfortable, .spacious]

    private func withDensity(_ preset: DensityPreset, _ body: (TabStripMetrics, CGFloat) -> Void) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        body(TabStripMetrics.standard, Metrics.tabHeight)
    }

    private static func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    @Test(arguments: presets)
    func theXIsHeliumsShareOfTheRow(_ preset: DensityPreset) {
        withDensity(preset) { m, row in
            #expect(m.closeButtonSize == Self.half(row * 14 / 28), "\(preset): hover square \(m.closeButtonSize) on a \(row) pt tab")
            #expect(m.contentTrailingInset == Self.half(row * 6 / 28), "\(preset): x to the pill's end \(m.contentTrailingInset)")
            #expect(m.closeGlyphInk == Self.half(row * 8 / 28), "\(preset): x ink \(m.closeGlyphInk)")
            #expect(m.closeCornerRadius == Self.half(m.closeButtonSize * 4 / 14), "\(preset): hover corner \(m.closeCornerRadius)")
        }
    }

    /// Helium's hover corner is the x's own, not nested in the pill: at Default the 14 pt square in the 28 pt,
    /// 8 pt pill rounds 4 pt, where the concentric rule would give 1.
    @Test func theHoverCornerIsTheXsOwnAtDefault() {
        withDensity(.cozy) { m, row in
            #expect(row == 28)
            #expect(m.closeButtonSize == 14)
            #expect(m.closeCornerRadius == 4)
        }
    }

    /// A smaller x keeps Apple's 20 x 20 pt click target around it.
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

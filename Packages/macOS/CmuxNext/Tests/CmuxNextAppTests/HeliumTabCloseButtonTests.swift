import CmuxNextDesign
@testable import CmuxNextTabs
import CoreGraphics
import Testing

/// A tab's x is Helium's, concentric with the tab (Lawrence msg 48706: "match helium in terms of shape + hover ... color
/// + shape + size + roundness etc must all match (and be concentric with the tab roundness itself)").
///
/// Helium (tabs.patch, tab_close_button.cc): a `RoundRectHighlightPathGenerator` plate. At its Default density that is a
/// 14 pt square with a 4 pt corner, which cannot nest in the 8 pt tab corner; at Spacious, `Insets(1)` on a 32 pt tab
/// gives a 24 pt plate 4 pt inside the pill, rounded 4 = 8 - 4. cmux draws that concentric plate at every density: half
/// the pill's corner in from its top, bottom and end, rounded with the rest. The ink is close_weight500_custom's: a
/// 2.25 unit stroke on 13.42 units of ink.
@MainActor @Suite(.serialized) struct HeliumTabCloseButtonTests {
    nonisolated static let presets = DensityPreset.allCases

    private func withDensity(_ preset: DensityPreset, _ body: (TabStripMetrics, CGFloat) -> Void) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        body(TabStripMetrics.standard, Metrics.tabHeight)
    }

    private static func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    /// The plate sits as far from the pill's top and bottom as from its end, and its corner is the pill's less that gap.
    @Test(arguments: presets)
    func thePlateIsConcentricWithTheTab(_ preset: DensityPreset) {
        withDensity(preset) { m, row in
            let outer = min(m.cornerRadius, row / 2)
            let gap = (row - m.closePlateSide) / 2
            #expect(gap == max(2, outer / 2), "\(preset): plate \(m.closePlateSide) on a \(row) pt tab with a \(outer) pt corner")
            #expect(m.closeCornerRadius == max(0, outer - gap), "\(preset): plate corner \(m.closeCornerRadius), gap \(gap)")
            // The slot's center is half a row from the pill's end, so the plate's end is `gap` from it too.
            #expect(m.contentTrailingInset + m.closeButtonSize / 2 == row / 2, "\(preset): x center \(m.contentTrailingInset + m.closeButtonSize / 2) pt in")
            // The slot keeps Helium's share of the row, so titles and minimum widths keep their room.
            #expect(m.closeButtonSize == Self.half(15 * CGFloat(preset.scaleFactor)))
            #expect(m.closeGlyphInk == Self.half(8.5 * CGFloat(preset.scaleFactor)), "\(preset): x ink \(m.closeGlyphInk)")
            #expect(abs(m.closeGlyphLineWidth - m.closeGlyphInk * 2.25 / 13.42) < 0.0001)
        }
    }

    /// Default's 30 pt tab with its 9 pt corner: a 21 pt plate 4.5 pt in, rounded 4.5, its x 15 pt from the end.
    @Test func theDefaultPlate() {
        withDensity(.cozy) { m, row in
            #expect(row == 30)
            #expect(m.cornerRadius == 9)
            #expect(m.closePlateSide == 21)
            #expect(m.closeCornerRadius == 4.5)
            #expect(m.contentTrailingInset == 7.5)
        }
    }

    /// A capsule tab (`appearance.tabShape` rounded) gets a round plate, concentric with its ends.
    @Test func aCapsuleTabGetsACircle() {
        let plate = BrowserChromeTuning.closePlate(pillHeight: 30, pillRadius: 15, minimumSide: 15)
        #expect(plate.side == 15 && plate.corner == 7.5)
        let square = BrowserChromeTuning.closePlate(pillHeight: 30, pillRadius: 0, minimumSide: 15)
        #expect(square.side == 26 && square.corner == 0, "a square tab: 2 pt in, square")
    }

    /// The click target covers the whole plate and keeps Apple's 20 x 20 pt minimum.
    @Test(arguments: presets)
    func theClickTargetCoversThePlate(_ preset: DensityPreset) {
        withDensity(preset) { m, _ in
            let drawn = CGRect(x: 100, y: 5, width: m.closeButtonSize, height: m.closeButtonSize)
            let hit = m.closeHitRect(drawn)
            #expect(hit.width >= max(20, m.closePlateSide) && hit.height >= max(20, m.closePlateSide), "\(preset): hit \(hit.size)")
            #expect(hit.midX == drawn.midX && hit.midY == drawn.midY)
        }
    }
}

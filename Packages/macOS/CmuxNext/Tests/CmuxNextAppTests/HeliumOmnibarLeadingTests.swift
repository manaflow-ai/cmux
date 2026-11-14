@testable import CmuxNextBrowser
import CmuxNextDesign
import CoreGraphics
import Testing

/// The omnibar's page-info chip and its text start where Helium's do at Default, Compact and Comfortable, and where
/// Chrome's do at Spacious (Lawrence 2026-11-13: "use helium for default, for spacious, still keep helium details,
/// but match chrome's sizing/padding").
///
/// Helium 0.21.3.1 on its 28 pt bar (location-bar.patch: leading decoration edge padding 2, inner padding 5, a 24 pt
/// decoration; 2x captures on cmux-lawrence-2 in plans/cmux-next/helium-density/refs): the chip's glyph centers 14 pt
/// in and the URL's text starts 31 pt in (2 + 24 + 5; its ink 31.5, the glyph's side bearing). Spacious keeps Chrome's column (Lucas 2026-11-14: the glyph 22 pt in and
/// the text 42 pt in on a 30 pt bar).
@MainActor @Suite(.serialized) struct HeliumOmnibarLeadingTests {
    private func withDensity(_ preset: DensityPreset, _ body: (CGFloat) -> Void) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        body(OmnibarStyle.barHeight)
    }

    private static func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    @Test(arguments: [DensityPreset.compact, .cozy, .comfortable])
    func theChipAndTextStartWhereHeliumsDo(_ preset: DensityPreset) {
        withDensity(preset) { bar in
            #expect(OmnibarStyle.chipLeading == max(OmnibarStyle.edgeInset, Self.half(bar * 2 / 28)), "\(preset): chip \(OmnibarStyle.chipLeading) in a \(bar) pt bar")
            let glyphCenter = OmnibarStyle.chipLeading + OmnibarStyle.chipSize / 2
            #expect(abs(glyphCenter - bar * 14 / 28) <= 0.5, "\(preset): chip glyph center \(glyphCenter)")
            #expect(abs(OmnibarStyle.textOrigin - bar * 31 / 28) <= 0.5, "\(preset): text \(OmnibarStyle.textOrigin)")
        }
    }

    /// At Default the chip's glyph sits 14 pt in and the URL's text 31 pt in, Helium's own numbers.
    @Test func defaultIsHeliumsOwnNumbers() {
        withDensity(.cozy) { bar in
            #expect(bar == 28)
            #expect(OmnibarStyle.chipLeading + OmnibarStyle.chipSize / 2 == 14)
            #expect(OmnibarStyle.textOrigin == 31)
        }
    }

    /// Spacious keeps Chrome's column: the glyph 22/30 of the bar in, the text's column 42/30.
    @Test func spaciousKeepsChromesColumn() {
        withDensity(.spacious) { bar in
            let chip = OmnibarStyle.chipLeading
            #expect(chip == max(OmnibarStyle.edgeInset, (bar * 22 / 30 - OmnibarStyle.chipSize / 2).rounded()))
            #expect(OmnibarStyle.textLeading == max(OmnibarStyle.fieldTrailingGap, (bar * 42 / 30 - chip - OmnibarStyle.chipSize).rounded()))
        }
    }
}

@testable import CmuxNextDesign
import CoreGraphics
import Testing

@MainActor @Suite(.serialized) struct PageRowScaleTests {
    @Test(arguments: DensityPreset.allCases)
    func rowScalesAreDefaultsTimesOneFactor(preset: DensityPreset) {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        let t = preset.scaleFactor
        #expect(abs(Typography.pageRowTextScale - t * Typography.userScale) < 0.0001)
        #expect(Typography.pageRowIconScale == (16.5 * CGFloat(t) * 2).rounded() / 2 / 16.5)
        #expect(abs(Typography.pageDensityScale - t) < 0.0001)
        let script = design.interfaceScaleScript()
        #expect(script.contains("setProperty('--cmux-composer-zoom', '\(String(format: "%g", t))')"))
        for name in ["pad-block", "text-size", "icon-size", "chip-text-size", "row-radius-extra"] {
            #expect(script.contains("setProperty('--cmux-composer-\(name)', '')"))
        }
    }
}

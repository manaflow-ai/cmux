@testable import CmuxNextBrowser
import CmuxNextDesign
import CoreGraphics
import Testing

@MainActor @Suite(.serialized) struct HeliumOmnibarLeadingTests {
    @Test(arguments: DensityPreset.allCases)
    func everyDensityKeepsDefaultsColumn(preset: DensityPreset) {
        DensityTokens.$scoped.withValue(preset.tokens) {
            let t = CGFloat(preset.omnibarScaleFactor) // Default's omnibar is Compact's
            func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
            let bar = preset == .cozy ? 34 : half(28 / 0.9 * t), edge = half(2 * t)
            let chip = min(half(25 * t), bar - 2 * edge)
            #expect(OmnibarStyle.barHeight == bar)
            #expect(OmnibarStyle.chipLeading == half(2 * t))
            #expect(OmnibarStyle.chipSize == chip)
            #expect(OmnibarStyle.textLeading == half(5 * t))
            #expect(OmnibarStyle.textOrigin == half(2 * t) + chip + half(5 * t))
            #expect(OmnibarStyle.buttonSpacing == half(3 * t))
            #expect(OmnibarStyle.barMargin == 2 * half(3 * t))
            #expect(OmnibarStyle.edgeInset == edge)
        }
    }
}

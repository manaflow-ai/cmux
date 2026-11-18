@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// The Density Overlay Playground's values (``BrowserChromeTuning``): each density has its own, so tuning Default's
/// x leaves Compact's as it was, and with none set every value is the Helium (or, at Spacious, Chrome) default.
@MainActor @Suite(.serialized) struct BrowserChromeTuningTests {
    @Test func everyDensityListsEveryMetricOnce() {
        let keys = BrowserChromeTuning.descriptors.map(\.key)
        #expect(keys.count == BrowserChromeTuning.densities.count * BrowserChromeMetric.allCases.count)
        #expect(Set(keys).count == keys.count)
        #expect(keys.contains("browserChrome.cozy.closeSize"))
    }

    @Test func anOverrideBelongsToOneDensity() {
        let store = TunableStore()
        store.activate(file: nil)
        store.register(BrowserChromeTuning.descriptors)
        store.set(BrowserChromeTuning.key(.closeSize, density: .cozy), .number(16))
        #expect(BrowserChromeTuning.override(.closeSize, tokens: DensityPreset.cozy.tokens, store: store) == 16)
        #expect(BrowserChromeTuning.override(.closeSize, tokens: DensityPreset.compact.tokens, store: store) == nil)
        #expect(BrowserChromeTuning.override(.closeSize, tokens: DensityPreset.ultraCompact.tokens, store: store) == nil)
    }

    @Test(arguments: [DensityPreset.compact, .cozy, .comfortable, .spacious])
    func defaultsFollowTheReference(preset: DensityPreset) {
        func derived(_ metric: BrowserChromeMetric) -> Double? {
            BrowserChromeTuning.all.first { $0.descriptor.key == BrowserChromeTuning.key(metric, density: preset) }.map { Double($0.derive()) }
        }
        func half(_ value: Double) -> Double { (value * 2).rounded() / 2 }
        #expect(derived(.rowHeight) == preset.tokens.tokens["browserRowHeight"])
        #expect(derived(.rowGap) == half(3 * preset.scaleFactor))
        #expect(derived(.closeSize) == half(15 * preset.scaleFactor))
        #expect(derived(.closeCorner) == half(4.5 * preset.scaleFactor))
        #expect(derived(.closeInk) == half(8.5 * preset.scaleFactor))
        #expect(derived(.closeTrailing) == half(6.5 * preset.scaleFactor))
        let o = preset.omnibarScaleFactor // Default's omnibar is Compact's
        #expect(derived(.chipLeading) == half(2 * o))
        let bar = preset == .cozy ? 34 : half(28 / 0.9 * o) // Default: Chrome's 34 pt bar
        #expect(derived(.textOrigin) == half(2 * o) + min(half(25 * o), bar - 2 * half(2 * o)) + half(5 * o))
    }
}

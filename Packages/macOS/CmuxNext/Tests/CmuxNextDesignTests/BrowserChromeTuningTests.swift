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
        // Default's own 5 (`defaultStripPadding`) times the factor from Default up (Spacious a half point more,
        // `spaciousGapNudge`); below Default, Default's 3 times it.
        let nudge = preset == .spacious ? DensityPreset.spaciousGapNudge : 0
        let rowGap: Double = preset.scaleFactor >= 1 ? half(DensityPreset.defaultStripPadding * preset.scaleFactor) + nudge : half(3 * preset.scaleFactor)
        #expect(derived(.rowGap) == rowGap)
        // Helium's x in its own points (Lawrence 2026-11-28: "size and icon size etc must perfectly match helium"): the
        // 14 pt square and icon, 7.83 pt of ink, a 4 pt corner, 6 pt from the end below a 32 pt row and 8 pt from it.
        let row = preset.tokens.tokens["browserRowHeight"] ?? 0
        #expect(derived(.closeSize) == 14)
        #expect(derived(.closeCorner) == 4)
        #expect(abs((derived(.closeInk) ?? 0) - 14 * 13.42 / 24) < 0.0001)
        #expect(derived(.closeTrailing) == (row >= 32 ? 8 : 6), "\(preset): row \(row)")
        let o = preset.omnibarScaleFactor // Default's omnibar is Compact's
        #expect(derived(.chipLeading) == half(2 * o))
        let bar = preset == .cozy ? 34 : half(28 / 0.9 * o) // Default: Chrome's 34 pt bar
        #expect(derived(.textOrigin) == half(2 * o) + min(half(25 * o), bar - 2 * half(2 * o)) + half(5 * o))
    }
}

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

    /// The defaults the descriptors show are each density's own: Helium's 28 pt row, 3 pt gap and 14 pt x at
    /// Default; Chrome's 34 pt row and 6 pt gap at Spacious.
    @Test func defaultsAreEachDensitysOwn() {
        func derived(_ metric: BrowserChromeMetric, _ density: DensityPreset) -> CGFloat? {
            BrowserChromeTuning.all.first { $0.descriptor.key == BrowserChromeTuning.key(metric, density: density) }?.derive()
        }
        #expect(derived(.rowHeight, .cozy) == 28)
        #expect(derived(.rowGap, .cozy) == 3)
        #expect(derived(.closeSize, .cozy) == 14)
        #expect(derived(.closeCorner, .cozy) == 4)
        #expect(derived(.chipLeading, .cozy) == 2)
        #expect(derived(.textOrigin, .cozy) == 31)
        #expect(derived(.rowHeight, .compact) == 20)
        #expect(derived(.rowHeight, .spacious) == 34)
        #expect(derived(.rowGap, .spacious) == 6)
    }
}

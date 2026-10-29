import CmuxNextFeatures
import Testing

/// Feature switch policy: the felt-queue switch `drainCauseSplit` is off in every channel until its redesign is judged PRINCIPLED by the principled-optimization audit (R4, on/off parity, is unproven; cmux-ad 2026-10-29).
/// `CMUX_ENABLE_FEATURES=drainCauseSplit` still turns it on for a measurement run.
struct FeatureSwitchOnFeltDrainCauseSplitTests {
    @Test func itIsOffInEveryChannelUntilItsRedesignIsPrincipled() {
        #expect(Feature.drainCauseSplit.defaults == FeatureDefaults(dev: false, nightly: false, release: false))
        for channel in Feature.Channel.allCases {
            #expect(FeatureList(registry: FeatureRegistry(), channel: channel).resolution(of: .drainCauseSplit)
                == Feature.Resolution(isEnabled: false, source: .channelDefault), "\(channel)")
        }
    }
}

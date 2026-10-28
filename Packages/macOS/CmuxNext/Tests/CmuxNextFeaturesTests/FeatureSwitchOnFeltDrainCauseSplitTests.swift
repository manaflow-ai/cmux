import CmuxNextFeatures
import Testing

/// Feature switch policy (plans/cmux-next/feature-switch-policy.md, rule 2, the measurement window): the felt-queue
/// switch `drainCauseSplit` is on by default in DEV and NIGHTLY, so the optimized dogfood build measures it, and off
/// in Release until a passing bench.
struct FeatureSwitchOnFeltDrainCauseSplitTests {
    @Test func itIsOnInDevAndNightlyAndOffInRelease() {
        #expect(Feature.drainCauseSplit.defaults == FeatureDefaults(dev: true, nightly: true, release: false))
        for channel in Feature.Channel.allCases {
            #expect(FeatureList(registry: FeatureRegistry(), channel: channel).resolution(of: .drainCauseSplit)
                == Feature.Resolution(isEnabled: channel != .release, source: .channelDefault), "\(channel)")
        }
    }
}

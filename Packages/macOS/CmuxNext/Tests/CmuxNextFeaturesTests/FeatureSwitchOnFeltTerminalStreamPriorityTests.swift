import CmuxNextFeatures
import Testing

/// Feature switch policy (plans/cmux-next/feature-switch-policy.md, rule 2, the measurement window; the felt
/// queue): `terminalStreamPriority` is on by default in DEV and NIGHTLY and stays off in Release, so DEV, NIGHTLY
/// and the optimized dogfood build run and measure it.
struct FeatureSwitchOnFeltTerminalStreamPriorityTests {
    @Test func itIsOnInDevAndNightlyAndOffInRelease() throws {
        let registry = FeatureRegistry()
        let feature = try #require(registry.feature(named: "terminalStreamPriority"), "terminalStreamPriority is not declared")
        #expect(feature.defaults == FeatureDefaults(dev: true, nightly: true, release: false), "\(feature.defaults)")
        for channel in Feature.Channel.allCases {
            #expect(FeatureList(registry: registry, channel: channel).resolution(of: feature)
                == Feature.Resolution(isEnabled: channel != .release, source: .channelDefault), "\(channel)")
        }
    }
}

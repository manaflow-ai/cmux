import CmuxNextFeatures
import Testing

/// Feature switch policy (plans/cmux-next/feature-switch-policy.md, rule 2, the measurement window):
/// `chromiumHostInputRing`, a felt-queue switch (felt switch list, handoff felt-queue.md), is on by default in DEV
/// and NIGHTLY and stays off in Release, so the optimized dogfood build can measure it against trunk before its 7
/// days run out.
struct FeatureSwitchOnFeltChromiumHostInputRingTests {
    static let name = "chromiumHostInputRing"

    @Test func itIsOnInDevAndNightlyAndOffInRelease() throws {
        let feature = try #require(FeatureRegistry().feature(named: Self.name), "\(Self.name) is not declared")
        let onInDevAndNightly = FeatureDefaults(dev: true, nightly: true, release: false)
        #expect(feature.defaults == onInDevAndNightly, "\(feature.defaults)")
    }

    @Test func aBuildWithNoInputResolvesItFromItsChannel() throws {
        let registry = FeatureRegistry()
        let feature = try #require(registry.feature(named: Self.name), "\(Self.name) is not declared")
        for channel in Feature.Channel.allCases {
            let resolution = FeatureList(registry: registry, channel: channel).resolution(of: feature)
            let expected = Feature.Resolution(isEnabled: channel != .release, source: .channelDefault)
            #expect(resolution == expected, "\(channel)")
        }
    }
}

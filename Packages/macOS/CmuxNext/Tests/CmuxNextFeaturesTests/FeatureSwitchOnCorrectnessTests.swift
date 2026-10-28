import CmuxNextFeatures
import Testing

/// Feature switch policy (plans/cmux-next/feature-switch-policy.md, rule 1), batch "correctness" (2026-10-28): UI,
/// telemetry display and discard-protection switches that make no perf claim and whose unit tests pass on the
/// fleet: each switch below is on by default in DEV and NIGHTLY and stays off in Release, so DEV, NIGHTLY and
/// dogfood builds run the path every day instead of only through a dogfood list.
struct FeatureSwitchOnCorrectnessTests {
    static let names = [
        "featureFlagsCard",
        "highEnergyTabs",
        "memoryFreezeEligibility",
        "memorySaverBackgroundActivity",
        "pageHangNotice",
        "recentlyAudibleProtection",
        "taskManagerMemorySaved",
    ]

    @Test func eachIsOnInDevAndNightlyAndOffInRelease() throws {
        let registry = FeatureRegistry()
        for name in Self.names {
            let feature = try #require(registry.feature(named: name), "\(name) is not declared")
            #expect(feature.defaults == FeatureDefaults(dev: true, nightly: true, release: false), "\(name): \(feature.defaults)")
        }
    }

    @Test func aBuildWithNoInputResolvesThemFromItsChannel() throws {
        let registry = FeatureRegistry()
        for channel in Feature.Channel.allCases {
            let list = FeatureList(registry: registry, channel: channel)
            for name in Self.names {
                let feature = try #require(registry.feature(named: name), "\(name) is not declared")
                #expect(list.resolution(of: feature) == Feature.Resolution(isEnabled: channel != .release, source: .channelDefault),
                        "\(name) in \(channel)")
            }
        }
    }
}

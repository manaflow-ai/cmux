import CmuxNextFeatures
import Testing

/// UI, telemetry display and discard-protection switches that make no perf claim: each switch below is off by default
/// in every channel. Slice 1 of the landing turns on no switch that feat-cmux-next lacks (cmux-ad 2026-10-30,
/// land-faster.md item 2); `CMUX_ENABLE_FEATURES` and the dogfood set still turn them on.
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

    @Test func eachIsOffInEveryChannel() throws {
        let registry = FeatureRegistry()
        for name in Self.names {
            let feature = try #require(registry.feature(named: name), "\(name) is not declared")
            #expect(feature.defaults == FeatureDefaults(dev: false, nightly: false, release: false), "\(name): \(feature.defaults)")
        }
    }

    @Test func aBuildWithNoInputResolvesThemFromItsChannel() throws {
        let registry = FeatureRegistry()
        for channel in Feature.Channel.allCases {
            let list = FeatureList(registry: registry, channel: channel)
            for name in Self.names {
                let feature = try #require(registry.feature(named: name), "\(name) is not declared")
                #expect(list.resolution(of: feature) == Feature.Resolution(isEnabled: false, source: .channelDefault),
                        "\(name) in \(channel)")
            }
        }
    }
}

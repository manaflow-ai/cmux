import CmuxNextFeatures
import Testing

/// `sidebarDocChunkedShow` is a felt-queue switch (handoff felt-queue.md): off by default in every channel. Slice 1
/// of the landing turns on no switch that feat-cmux-next lacks (cmux-ad 2026-10-30, land-faster.md item 2);
/// `CMUX_ENABLE_FEATURES=sidebarDocChunkedShow` still turns it on for a bench run.
struct FeatureSwitchOnFeltSidebarDocChunkedShowTests {
    @Test func isOffInEveryChannel() throws {
        let feature = try #require(FeatureRegistry().feature(named: "sidebarDocChunkedShow"), "sidebarDocChunkedShow is not declared")
        #expect(feature.defaults == FeatureDefaults(dev: false, nightly: false, release: false), "\(feature.defaults)")
    }

    @Test func aBuildWithNoInputResolvesItFromItsChannel() throws {
        let registry = FeatureRegistry()
        let feature = try #require(registry.feature(named: "sidebarDocChunkedShow"), "sidebarDocChunkedShow is not declared")
        for channel in Feature.Channel.allCases {
            #expect(FeatureList(registry: registry, channel: channel).resolution(of: feature)
                        == Feature.Resolution(isEnabled: false, source: .channelDefault), "\(channel)")
        }
    }
}

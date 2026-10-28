import CmuxNextFeatures
import Testing

// The host-mode switches are benchOnly: declared only in Debug and bench builds, so these tests exist only there.
#if DEBUG || CMUX_BENCH_HOOKS
/// Feature switch policy (plans/cmux-next/feature-switch-policy.md, rule 1), batch "host mode" (2026-10-28): the
/// Chromium Host mode switches, which act only while Chromium tabs run in the host (cefHelperHost, Debug and bench
/// builds) and whose unit tests pass on the fleet: each switch below is on by default in DEV and NIGHTLY and stays
/// off in Release. Host mode exists only in Debug and bench builds (ChromiumHostSupervisor is compiled only there), so
/// these switches are benchOnly: a Debug DEV or NIGHTLY build runs the path every day; a shipped NIGHTLY or Release app
/// declares none of them. Turning host mode on in a shipped build takes benchOnly and the guard off again together.
struct FeatureSwitchOnHostModeTests {
    static let names = [
        "chromiumHostChoosers",
        "chromiumHostFileDialogs",
        "chromiumHostHangBanner",
        "chromiumHostPopupMenus",
        "chromiumHostSuggestions",
        "chromiumHostWidgets",
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
#endif

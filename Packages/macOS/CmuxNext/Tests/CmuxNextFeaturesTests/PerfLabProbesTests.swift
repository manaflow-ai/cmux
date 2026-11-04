#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextFeatures
import Testing

/// The launch report of the perf lab kill probe (`perfLabKillProbe`; plans/cmux-next/chrome-parity/p12-perf-process.md
/// 3.9).
struct PerfLabProbesTests {
    @Test func killProbeIsOnByDefaultOnEveryChannel() {
        for channel in Feature.Channel.allCases {
            let report = PerfLabFeatureReport(FeatureList(registry: FeatureRegistry(), channel: channel))
            #expect(report.killProbe == Feature.Resolution(isEnabled: true, source: .channelDefault))
        }
    }

    @Test func killProbeIsAStickyKillSwitch() {
        #expect(Feature.perfLabKillProbe.kind == .killSwitch)
        #expect(Feature.perfLabKillProbe.sticky)
    }

    @Test func reportShowsARemoteKillOfTheProbe() {
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                   overrides: FeatureOverrides(remote: ["perfLabKillProbe": false]))
        let report = PerfLabFeatureReport(features)
        #expect(report.killProbe == Feature.Resolution(isEnabled: false, source: .remote))
        #expect(report.line == "perf lab: perfLabKillProbe=off source=remote")
    }
}
#endif

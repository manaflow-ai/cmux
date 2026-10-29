import CmuxNextFeatures
import Testing

/// Terminal views attach as streams on the control connection by default in DEV and NIGHTLY (so in
/// dogfood builds), and `CMUX_DISABLE_FEATURES=terminalStreams` keeps one connection per view
/// (plans/cmux-next/app-daemon-connection-DESIGN.md section 6). Release stays off until the spec's optimized-build
/// benches pass and NIGHTLY has run it for 7 days (plans/cmux-next/feature-switch-policy.md rule 5).
struct TerminalStreamsDefaultTests {
    @Test func terminalStreamsAreOnByDefaultInDevAndNightlyAndOffInRelease() {
        for channel in Feature.Channel.allCases {
            let list = FeatureList(registry: FeatureRegistry(), channel: channel)
            #expect(list.resolution(of: Feature.terminalStreams)
                == Feature.Resolution(isEnabled: channel != .release, source: .channelDefault), "\(channel)")
        }
    }

    @Test func theEnvironmentStillTurnsTerminalStreamsOff() {
        let overrides = FeatureOverrides(environment: [FeatureOverrides.disableVariable: "terminalStreams"])
        for channel in Feature.Channel.allCases {
            let list = FeatureList(registry: FeatureRegistry(), channel: channel, overrides: overrides)
            #expect(list.resolution(of: Feature.terminalStreams)
                == Feature.Resolution(isEnabled: false, source: .environment), "\(channel)")
        }
    }
}

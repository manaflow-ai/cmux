import CmuxNextFeatures
import Testing

/// p05-ipc-094: terminal views attach as streams on the control connection by default in every channel, and for
/// one release `CMUX_DISABLE_FEATURES=terminalStreams` keeps one connection per view
/// (plans/cmux-next/app-daemon-connection-DESIGN.md section 6).
struct TerminalStreamsDefaultTests {
    @Test func terminalStreamsAreOnByDefaultInEveryChannel() {
        for channel in Feature.Channel.allCases {
            let list = FeatureList(registry: FeatureRegistry(), channel: channel)
            #expect(list.resolution(of: Feature.terminalStreams)
                == Feature.Resolution(isEnabled: true, source: .channelDefault), "\(channel)")
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

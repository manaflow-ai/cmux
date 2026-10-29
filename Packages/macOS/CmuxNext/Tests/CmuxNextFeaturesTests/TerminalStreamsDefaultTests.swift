import CmuxNextFeatures
import Testing

/// Terminal views keep one connection per view by default: `terminalStreams` is off in every channel until its redesign is judged PRINCIPLED by the principled-optimization audit (R4, on/off parity, is unproven; cmux-ad 2026-10-29).
/// `CMUX_ENABLE_FEATURES=terminalStreams` still attaches them as streams on the control connection
/// (plans/cmux-next/app-daemon-connection-DESIGN.md section 6), and `CMUX_DISABLE_FEATURES` keeps them off.
struct TerminalStreamsDefaultTests {
    @Test func terminalStreamsAreOffByDefaultInEveryChannel() {
        for channel in Feature.Channel.allCases {
            let list = FeatureList(registry: FeatureRegistry(), channel: channel)
            #expect(list.resolution(of: Feature.terminalStreams)
                == Feature.Resolution(isEnabled: false, source: .channelDefault), "\(channel)")
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

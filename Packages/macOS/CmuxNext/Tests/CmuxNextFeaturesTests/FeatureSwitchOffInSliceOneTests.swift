import CmuxNextFeatures
import Testing

/// Slice 1 of the landing turns on no switch that feat-cmux-next lacks (cmux-ad 2026-10-30, land-faster.md item 2):
/// these switches had no batch test of their own that pinned their default. `terminalHolder` (the PTY holder) is off
/// as on feat-cmux-next, where it runs only with `CMUX_TUI_TERMINAL_HOST_MODEL=holder`; `fatalHangReports` and
/// `traceControl` are off in every channel too. `CMUX_ENABLE_FEATURES` still turns each on for one launch.
struct FeatureSwitchOffInSliceOneTests {
    static let features: [Feature] = [.terminalHolder, .fatalHangReports, .traceControl]

    @Test func eachIsOffInEveryChannel() {
        for feature in Self.features {
            #expect(feature.defaults == FeatureDefaults(dev: false, nightly: false, release: false), "\(feature.name): \(feature.defaults)")
            for channel in Feature.Channel.allCases {
                #expect(FeatureList(registry: FeatureRegistry(), channel: channel).resolution(of: feature)
                    == Feature.Resolution(isEnabled: false, source: .channelDefault), "\(feature.name) in \(channel)")
            }
        }
    }

    @Test func theEnableListStillTurnsEachOnForOneLaunch() {
        for feature in Self.features {
            let list = FeatureList(registry: FeatureRegistry(), channel: .release,
                                   overrides: FeatureOverrides(environment: [FeatureOverrides.enableVariable: feature.name]))
            #expect(list.resolution(of: feature) == Feature.Resolution(isEnabled: true, source: .environment), "\(feature.name)")
        }
    }
}

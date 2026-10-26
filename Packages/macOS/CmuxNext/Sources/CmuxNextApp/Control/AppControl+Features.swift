import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDesign
import CmuxNextFeatures

/// The feature values the control socket reports (`features.list`) and the Chromium host app reads
/// (`cefHelperHost`, `chromiumHostIdleExit`).
extension AppControl {
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The Chromium host's idle deadline: `chromiumHostIdleExit`'s `idleExitAfter` while the
    /// feature is on, else nil (the host runs while its session does).
    static func chromiumHostIdleExit(in features: FeatureList) -> Duration? {
        guard features.isEnabled(.chromiumHostIdleExit) else { return nil }
        for param in Feature.chromiumHostIdleExit.params where param.name == "idleExitAfter" {
            if case .duration(let seconds, _, _) = param.value { return .seconds(seconds) }
        }
        return nil
    }

    /// The Chromium host's switch: the launch's `cefHelperHost`, which Debug Settings
    /// `browserHost.helper` overrides in FeatureList's order: below policy and the
    /// environment, above remote, trial and the channel default, never in Release.
    static func chromiumHostSwitch(in features: FeatureList, tunables: TunableStore) -> BrowserHostSwitch {
        let launch = features.resolution(of: .cefHelperHost)
        let decidedAboveLocal = launch.source == .policy || launch.source == .environment
        return BrowserHostSwitch(launchValue: launch.isEnabled,
                                 takesLocalOverride: features.channel.allowsLocalOverrides && !decidedAboveLocal, tunables: tunables)
    }
    #endif

    /// `features.list` and the Labs card's report: the launch's list, with each Debug toggle that still overrides a
    /// feature after launch (`browserHost.helper` over `cefHelperHost`, read as the switch reads it), so a row says
    /// what the app runs with, source `local`, and a bench's features snapshot names the arm it measured.
    static func featureFlagsReport(_ features: FeatureList, tunables: TunableStore) -> FeatureFlagsReport {
        #if DEBUG || CMUX_BENCH_HOOKS
        let hostSwitch = chromiumHostSwitch(in: features, tunables: tunables)
        let hostToggle: FeatureFlagsReport.LiveLocalOverride = { hostSwitch.localOverride }
        return FeatureFlagsReport(features: features, liveLocal: [Feature.cefHelperHost.name: hostToggle])
        #else
        return FeatureFlagsReport(features: features)
        #endif
    }
}

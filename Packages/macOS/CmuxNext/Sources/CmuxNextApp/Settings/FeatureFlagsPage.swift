import CmuxNextActions
import CmuxNextControl
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextSettings

/// Help > Feature Flags (`help.featureFlags`, CLI name `settings open-feature-flags`):
/// opens Settings > Experimental at its Labs rows (`labs.*`). With feature
/// `featureFlagsCard` on, the same category ends with the Feature Flags card:
/// every declared feature's state and source (the socket's `features.list`,
/// `FeatureFlagsReport`, which `cmux settings feature-flags [--json]` prints).
struct FeatureFlagsPage {
    /// The first Labs row: the anchor Settings scrolls to.
    static let settingKey = CmuxConfigSnapshot.previewFeaturesPath.joined(separator: ".")

    let services: AppServices

    func open(_ invocation: ActionInvocation) throws {
        try services.settingsWindow.show(section: nil, setting: Self.settingKey, focus: invocation.allowsViewChange)
    }

    /// What `features.list` and the card show: the launch's list, with each Debug toggle that still overrides a
    /// feature after launch read as its reader reads it (`browserHost.helper` over `cefHelperHost`, through the
    /// Chromium host's switch), so each row is the value the app runs with and a bench records the arm it measured.
    static func report(_ features: FeatureList, tunables: TunableStore) -> FeatureFlagsReport {
        #if DEBUG || CMUX_BENCH_HOOKS
        let hostSwitch = AppControl.chromiumHostSwitch(in: features, tunables: tunables)
        return FeatureFlagsReport(features: features, liveLocal: [Feature.cefHelperHost.name: { hostSwitch.localOverride }])
        #else
        return FeatureFlagsReport(features: features)
        #endif
    }
}

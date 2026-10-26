import CmuxNextActions
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
}

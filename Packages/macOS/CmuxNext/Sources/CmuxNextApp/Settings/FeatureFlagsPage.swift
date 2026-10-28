import CmuxNextActions
import CmuxNextSettings

/// Help > Feature Flags (`help.featureFlags`, `cmux settings feature-flags`):
/// cmux-next's feature flags are the Labs toggles (`labs.*`, Settings >
/// Advanced > Labs), so the action opens Settings there.
struct FeatureFlagsPage {
    /// The first Labs row: the anchor Settings scrolls to.
    static let settingKey = CmuxConfigSnapshot.previewFeaturesPath.joined(separator: ".")

    let services: AppServices

    func open(_ invocation: ActionInvocation) throws {
        try services.settingsWindow.show(section: nil, setting: Self.settingKey, focus: invocation.allowsViewChange)
    }
}

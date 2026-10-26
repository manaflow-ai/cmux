import CmuxNextActions
import CmuxNextSettings

/// Help > Feature Flags (`help.featureFlags`): cmux-next's person-facing
/// flags are the Labs toggles (`labs.*`, Settings > Advanced > Labs), so the
/// action opens Settings there. `cmux settings feature-flags [--json]` lists
/// every declared feature with its state and source instead (the socket's
/// `features.list`, `FeatureFlagsReport`).
struct FeatureFlagsPage {
    /// The first Labs row: the anchor Settings scrolls to.
    static let settingKey = CmuxConfigSnapshot.previewFeaturesPath.joined(separator: ".")

    let services: AppServices

    func open(_ invocation: ActionInvocation) throws {
        try services.settingsWindow.show(section: nil, setting: Self.settingKey, focus: invocation.allowsViewChange)
    }
}

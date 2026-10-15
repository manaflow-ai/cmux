import CmuxSettings
import Foundation

/// Independent visibility preferences for remote workspace identities.
struct SidebarWorkspaceIdentitySettings: Equatable {
    let showCloudWorkspaceIdentity: Bool
    let showLocalDeviceIdentity: Bool

    init(defaults: UserDefaults) {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let sidebar = SidebarCatalogSection()
        let legacy = sidebar.showCloudDeviceIcons
        showCloudWorkspaceIdentity = Self.value(
            for: sidebar.showCloudWorkspaceIdentity,
            defaults: defaults,
            settings: settings,
            legacy: legacy
        )
        showLocalDeviceIdentity = Self.value(
            for: sidebar.showLocalDeviceIdentity,
            defaults: defaults,
            settings: settings,
            legacy: legacy
        )
    }

    private static func value(
        for setting: DefaultsKey<Bool>,
        defaults: UserDefaults,
        settings: UserDefaultsSettingsClient,
        legacy: DefaultsKey<Bool>
    ) -> Bool {
        guard defaults.object(forKey: setting.userDefaultsKey) == nil else {
            return settings.value(for: setting)
        }
        return settings.value(for: legacy)
    }

    /// Returns the visible identity label for the workspace category.
    func badgeLabel(deviceWorkspaceLabel: String?, remoteWorkspaceBadgeLabel: String?) -> String? {
        let isEnabled = deviceWorkspaceLabel == nil
            ? showCloudWorkspaceIdentity
            : showLocalDeviceIdentity
        return isEnabled ? remoteWorkspaceBadgeLabel : nil
    }
}

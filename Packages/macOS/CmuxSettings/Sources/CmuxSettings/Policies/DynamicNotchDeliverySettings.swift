import Foundation

/// Shared mapping between the Dynamic Notch on/off control and the persisted
/// notification delivery mode.
public enum DynamicNotchDeliverySettings {
    public static func isEnabled(
        mode: NotificationDeliveryMode
    ) -> Bool {
        mode == .dynamicNotch
    }

    public static func mode(
        enabled: Bool
    ) -> NotificationDeliveryMode {
        enabled ? .dynamicNotch : .system
    }

    public static func isEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = SettingCatalog().notifications.delivery
        return isEnabled(
            mode: UserDefaultsSettingsClient(defaults: defaults)
                .value(for: key)
        )
    }

    public static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        UserDefaultsSettingsClient(defaults: defaults).set(
            mode(enabled: enabled),
            for: SettingCatalog().notifications.delivery
        )
    }
}

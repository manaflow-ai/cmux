public import Foundation

/// User-configurable notification preferences the iOS settings UI stores
/// locally and syncs to the paired Mac's forwarding settings.
public struct MobileNotificationPreferences: Equatable, Sendable {
    /// Local iOS APNs opt-in key, shared with the push-registration service.
    public static let enabledKey = "cmux.notifications.pushEnabled"
    /// Forwarding mode key mirrored to the Mac's `PhonePushSettings.forwardModeKey`.
    public static let forwardingModeKey = "forwardNotificationsToPhoneMode"
    /// Hide-content key mirrored to the Mac's `PhonePushSettings.hideContentKey`.
    public static let hideContentKey = "forwardNotificationsHideContent"

    /// Whether iOS push registration and Mac forwarding are enabled.
    public var isEnabled: Bool
    /// When the Mac should forward terminal notifications to the phone.
    public var forwardingMode: MobileNotificationForwardingMode
    /// Whether the Mac should send generic notification text instead of terminal content.
    public var hidesContent: Bool

    /// Creates a notification-preferences value.
    public init(
        isEnabled: Bool,
        forwardingMode: MobileNotificationForwardingMode,
        hidesContent: Bool
    ) {
        self.isEnabled = isEnabled
        self.forwardingMode = forwardingMode
        self.hidesContent = hidesContent
    }

    /// Reads preferences from a `UserDefaults` store.
    /// - Parameter defaults: The defaults suite backing the iOS settings UI.
    public init(defaults: UserDefaults) {
        let rawMode = defaults.string(forKey: Self.forwardingModeKey)
        self.init(
            isEnabled: defaults.bool(forKey: Self.enabledKey),
            forwardingMode: rawMode.flatMap(MobileNotificationForwardingMode.init(rawValue:))
                ?? MobileNotificationForwardingMode.defaultMode,
            hidesContent: defaults.bool(forKey: Self.hideContentKey)
        )
    }

    /// Persists the preferences to a `UserDefaults` store.
    /// - Parameter defaults: The defaults suite backing the iOS settings UI.
    public func persist(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(forwardingMode.rawValue, forKey: Self.forwardingModeKey)
        defaults.set(hidesContent, forKey: Self.hideContentKey)
    }
}

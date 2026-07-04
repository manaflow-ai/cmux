public import Foundation

/// User-configurable notification preferences the iOS settings UI stores
/// locally and syncs to the paired Mac's forwarding settings.
public struct MobileNotificationPreferences: Equatable, Sendable {
    /// Local iOS APNs opt-in key, shared with the push-registration service.
    public static let enabledKey = "cmux.notifications.pushEnabled"
    /// Mac forwarding master toggle mirrored from `PhonePushSettings.forwardEnabledKey`.
    public static let forwardingEnabledKey = "forwardNotificationsToPhone"
    /// Forwarding mode key mirrored to the Mac's `PhonePushSettings.forwardModeKey`.
    public static let forwardingModeKey = "forwardNotificationsToPhoneMode"
    /// Hide-content key mirrored to the Mac's `PhonePushSettings.hideContentKey`.
    public static let hideContentKey = "forwardNotificationsHideContent"

    /// Whether this iPhone is locally opted into APNs registration.
    public var isEnabled: Bool
    /// Whether the paired Mac currently forwards notifications to phones.
    public var isForwardingEnabled: Bool
    /// When the Mac should forward terminal notifications to the phone.
    public var forwardingMode: MobileNotificationForwardingMode
    /// Whether the Mac should send generic notification text instead of terminal content.
    public var hidesContent: Bool

    /// Whether this phone should effectively receive forwarded notifications.
    public var receivesNotifications: Bool {
        isEnabled && isForwardingEnabled
    }

    /// The forwarding mode a first phone opt-in should write to the Mac.
    ///
    /// Existing enabled Mac forwarding keeps its selected mode. A disabled Mac
    /// forwarding gate may only be exposing its legacy away-only default, so the
    /// phone opt-in starts from the phone-active default instead.
    public var forwardingModeForPhoneOptIn: MobileNotificationForwardingMode {
        isForwardingEnabled ? forwardingMode : MobileNotificationForwardingMode.defaultMode
    }

    /// Creates a notification-preferences value.
    public init(
        isEnabled: Bool,
        isForwardingEnabled: Bool = true,
        forwardingMode: MobileNotificationForwardingMode,
        hidesContent: Bool
    ) {
        self.isEnabled = isEnabled
        self.isForwardingEnabled = isForwardingEnabled
        self.forwardingMode = forwardingMode
        self.hidesContent = hidesContent
    }

    /// Reads preferences from a `UserDefaults` store.
    /// - Parameter defaults: The defaults suite backing the iOS settings UI.
    public init(defaults: UserDefaults) {
        let isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        let isForwardingEnabled = defaults.object(forKey: Self.forwardingEnabledKey) as? Bool
        let rawMode = defaults.string(forKey: Self.forwardingModeKey)
        self.init(
            isEnabled: isEnabled,
            isForwardingEnabled: isForwardingEnabled ?? isEnabled,
            forwardingMode: rawMode.flatMap(MobileNotificationForwardingMode.init(rawValue:))
                ?? MobileNotificationForwardingMode.defaultMode,
            hidesContent: defaults.bool(forKey: Self.hideContentKey)
        )
    }

    /// Persists the preferences to a `UserDefaults` store.
    /// - Parameter defaults: The defaults suite backing the iOS settings UI.
    public func persist(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(isForwardingEnabled, forKey: Self.forwardingEnabledKey)
        defaults.set(forwardingMode.rawValue, forKey: Self.forwardingModeKey)
        defaults.set(hidesContent, forKey: Self.hideContentKey)
    }
}

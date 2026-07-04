#if os(iOS)
import Foundation
import CmuxMobileShellModel

extension MobilePushCoordinator {
    private static var notificationSettingsSyncPendingKey: String {
        "forwardNotificationsToPhoneSyncPending"
    }

    private static var notificationSettingsSyncPendingMacKey: String {
        "forwardNotificationsToPhoneSyncPendingMacDeviceID"
    }

    private static var notificationSettingsSyncPendingModeKey: String {
        "forwardNotificationsToPhoneSyncPendingHasMode"
    }

    private static var notificationSettingsSyncPendingHideContentKey: String {
        "forwardNotificationsToPhoneSyncPendingHasHideContent"
    }

    private static var notificationSettingsSyncPendingPhoneOptInModeKey: String {
        "forwardNotificationsToPhoneSyncPendingPhoneOptInMode"
    }

    var hasPendingForwardingSync: Bool {
        defaults.object(forKey: Self.notificationSettingsSyncPendingKey) as? Bool == true
    }

    var storedNotificationOptIn: Bool? {
        defaults.object(forKey: MobileNotificationPreferences.enabledKey) as? Bool
    }

    var storedForwardingModePreference: MobileNotificationForwardingMode? {
        defaults.string(forKey: MobileNotificationPreferences.forwardingModeKey)
            .flatMap(MobileNotificationForwardingMode.init(rawValue:))
    }

    var storedHideContentPreference: Bool? {
        defaults.object(forKey: MobileNotificationPreferences.hideContentKey) as? Bool
    }

    var pendingForwardingSyncHasAuthoritativeForwardingMode: Bool {
        defaults.object(forKey: Self.notificationSettingsSyncPendingModeKey) as? Bool ?? false
    }

    var pendingForwardingSyncHasAuthoritativeHidesContent: Bool {
        defaults.object(forKey: Self.notificationSettingsSyncPendingHideContentKey) as? Bool ?? false
    }

    var pendingForwardingSyncUsesPhoneOptInForwardingDefault: Bool {
        defaults.object(forKey: Self.notificationSettingsSyncPendingPhoneOptInModeKey) as? Bool ?? false
    }

    func pendingForwardingSyncMatches(currentMacDeviceID: String?) -> Bool {
        guard let pendingMac = normalizedPendingMacDeviceID else { return true }
        return pendingMac == Self.normalizedMacDeviceID(currentMacDeviceID)
    }

    func markNotificationSettingsSyncPending(
        hasAuthoritativeForwardingMode: Bool,
        hasAuthoritativeHidesContent: Bool,
        usePhoneOptInForwardingDefault: Bool,
        currentMacDeviceID: String?
    ) {
        defaults.set(true, forKey: Self.notificationSettingsSyncPendingKey)
        defaults.set(hasAuthoritativeForwardingMode, forKey: Self.notificationSettingsSyncPendingModeKey)
        defaults.set(hasAuthoritativeHidesContent, forKey: Self.notificationSettingsSyncPendingHideContentKey)
        defaults.set(usePhoneOptInForwardingDefault, forKey: Self.notificationSettingsSyncPendingPhoneOptInModeKey)
        if let macDeviceID = Self.normalizedMacDeviceID(currentMacDeviceID) {
            defaults.set(macDeviceID, forKey: Self.notificationSettingsSyncPendingMacKey)
        } else {
            defaults.removeObject(forKey: Self.notificationSettingsSyncPendingMacKey)
        }
    }

    func clearNotificationSettingsSyncPending() {
        defaults.removeObject(forKey: Self.notificationSettingsSyncPendingKey)
        defaults.removeObject(forKey: Self.notificationSettingsSyncPendingMacKey)
        defaults.removeObject(forKey: Self.notificationSettingsSyncPendingModeKey)
        defaults.removeObject(forKey: Self.notificationSettingsSyncPendingHideContentKey)
        defaults.removeObject(forKey: Self.notificationSettingsSyncPendingPhoneOptInModeKey)
    }

    func claimNotificationSettingsSyncGeneration() -> UInt64 {
        notificationSettingsSyncGeneration &+= 1
        return notificationSettingsSyncGeneration
    }

    func isCurrentNotificationSettingsSync(_ generation: UInt64) -> Bool {
        generation == notificationSettingsSyncGeneration
    }

    private var normalizedPendingMacDeviceID: String? {
        Self.normalizedMacDeviceID(defaults.string(forKey: Self.notificationSettingsSyncPendingMacKey))
    }

    private static func normalizedMacDeviceID(_ macDeviceID: String?) -> String? {
        let trimmed = macDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
#endif

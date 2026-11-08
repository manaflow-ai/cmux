package import CmuxNextSettings
import Foundation
import UserNotifications

/// Reads and asks for this app's notification permission (the seam tests replace).
package nonisolated protocol NotificationPermissionCenter: Sendable {
    func status() async -> NotificationPermission
    /// Shows the macOS prompt while the permission is not determined, then reads it.
    func request() async throws -> NotificationPermission
}

/// This app's notification permission, as `notifications.status` reports it.
package nonisolated struct NotificationPermission: Equatable, Sendable {
    package var authorization: String
    package var alert: Bool
    /// The banner style macOS shows: none, banner, alert (or unknown).
    package var alertStyle: String
    package var sound: Bool
    package var badge: Bool
    package var bundleID: String?

    package var json: JSONValue {
        ["authorization": .string(authorization), "alert": .bool(alert), "alert_style": .string(alertStyle),
         "sound": .bool(sound), "badge": .bool(badge), "bundle_id": bundleID.map(JSONValue.string) ?? .null]
    }
}

/// The permission on the system center, which `DesktopNotifier` configured first.
package nonisolated struct SystemNotificationPermission: NotificationPermissionCenter {
    let bundleID: String?
    /// The person's answer to a request (for the banners' own record).
    let onAnswer: @Sendable (Bool) -> Void

    package func status() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorization = switch settings.authorizationStatus {
        case .notDetermined: "not_determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        @unknown default: "unknown"
        }
        let alertStyle = switch settings.alertStyle {
        case .none: "none"
        case .banner: "banner"
        case .alert: "alert"
        @unknown default: "unknown"
        }
        return NotificationPermission(authorization: authorization, alert: settings.alertSetting == .enabled,
                                      alertStyle: alertStyle, sound: settings.soundSetting == .enabled,
                                      badge: settings.badgeSetting == .enabled, bundleID: bundleID)
    }

    package func request() async throws -> NotificationPermission {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        onAnswer(granted)
        return await status()
    }
}

struct NotificationPermissionStrings {
    static var unavailable: String {
        String(localized: "notifications.permission.unavailable",
               defaultValue: "This cmux process does not use macOS notifications (an automation or test host, or not the cmux app bundle)",
               bundle: .module)
    }
}

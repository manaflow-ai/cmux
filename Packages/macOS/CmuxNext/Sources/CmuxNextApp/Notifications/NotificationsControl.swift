import CmuxNextControl
import CmuxNextSettings
import Foundation
import UserNotifications

/// `notifications.status`: whether macOS lets cmux show notifications, read without prompting
/// (`UNUserNotificationCenter.notificationSettings`): `{authorization, alert, alert_style, sound,
/// badge, bundle_id}`, `authorization` one of not_determined, denied, authorized, provisional,
/// unknown; `alert_style` one of none, banner, alert, unknown (`alert` can stay true with the
/// style None: only `alert_style` says whether a banner shows).
///
/// `notifications.request`: asks for it (`requestAuthorization`, the macOS prompt, shown only
/// while it is not_determined: the person's one click) and answers the status after.
/// `cmux setup notifications` reads one and asks with the other. A launch that never uses the
/// system center (an automation launch, a GUI job, a host that is not the app bundle) answers
/// `unavailable`. Not in the remote relay allowlist: an ssh session has no business prompting.
enum NotificationsControl {
    /// The macOS prompt waits for the person; the system bounds it, this only ends a lost one.
    static let requestDeadline: Duration = .seconds(600)

    static func methods(services: AppServices) -> [ControlMethod] {
        methods { [weak services] in try services?.notifications.desktop.permission() }
    }

    /// The methods over `center`, made on the main actor for each call (nil: the app is closing).
    /// On the main actor because `DesktopNotifier` is main-actor-only; the settings read itself runs
    /// off the main actor in the follow-up.
    static func methods(center make: @escaping @MainActor @Sendable () throws -> (any NotificationPermissionCenter)?) -> [ControlMethod] {
        [
            .mainActor("notifications.status") { _ in
                guard let center = try make() else { return .value(.null) }
                return .followUp { await center.status().json }
            },
            .mainActor("notifications.request") { _ in
                guard let center = try make() else { return .value(.null) }
                return .followUp { try await center.request().json }
            }.withDeadline(.fixed(requestDeadline)),
        ]
    }
}

/// Reads and asks for this app's notification permission (the seam tests replace).
nonisolated protocol NotificationPermissionCenter: Sendable {
    func status() async -> NotificationPermission
    /// Shows the macOS prompt while the permission is not determined, then reads it.
    func request() async throws -> NotificationPermission
}

/// This app's notification permission, as `notifications.status` reports it.
nonisolated struct NotificationPermission: Equatable, Sendable {
    var authorization: String
    var alert: Bool
    /// The banner style macOS shows: none, banner, alert (or unknown).
    var alertStyle: String
    var sound: Bool
    var badge: Bool
    var bundleID: String?

    var json: JSONValue {
        ["authorization": .string(authorization), "alert": .bool(alert), "alert_style": .string(alertStyle),
         "sound": .bool(sound), "badge": .bool(badge), "bundle_id": bundleID.map(JSONValue.string) ?? .null]
    }
}

/// The permission on the system center, which `DesktopNotifier` configured first.
nonisolated struct SystemNotificationPermission: NotificationPermissionCenter {
    let bundleID: String?
    /// The person's answer to a request (for the banners' own record).
    let onAnswer: @Sendable (Bool) -> Void

    func status() async -> NotificationPermission {
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

    func request() async throws -> NotificationPermission {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        onAnswer(granted)
        return await status()
    }
}

enum NotificationPermissionStrings {
    static var unavailable: String {
        String(localized: "notifications.permission.unavailable",
               defaultValue: "This cmux process does not use macOS notifications (an automation or test host, or not the cmux app bundle)",
               bundle: .module)
    }
}

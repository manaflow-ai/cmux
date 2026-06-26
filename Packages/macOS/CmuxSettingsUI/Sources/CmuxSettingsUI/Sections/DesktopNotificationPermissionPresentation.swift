import Foundation

struct DesktopNotificationPermissionPresentation: Equatable, Sendable {
    var statusLabel: DesktopNotificationPermissionStatusLabel
    var subtitle: DesktopNotificationPermissionSubtitle
    var primaryAction: DesktopNotificationPermissionAction?
    var sendTestEnabled: Bool

    static func make(
        for state: DesktopNotificationAuthorizationState
    ) -> DesktopNotificationPermissionPresentation {
        switch state {
        case .unknown:
            return DesktopNotificationPermissionPresentation(
                statusLabel: .unknown,
                subtitle: .notDetermined,
                primaryAction: nil,
                sendTestEnabled: false
            )
        case .notDetermined:
            return DesktopNotificationPermissionPresentation(
                statusLabel: .notRequested,
                subtitle: .notDetermined,
                primaryAction: .requestAuthorization,
                sendTestEnabled: false
            )
        case .authorized:
            return DesktopNotificationPermissionPresentation(
                statusLabel: .allowed,
                subtitle: .allowed,
                primaryAction: .openSystemSettings,
                sendTestEnabled: true
            )
        case .denied:
            return DesktopNotificationPermissionPresentation(
                statusLabel: .denied,
                subtitle: .denied,
                primaryAction: .openSystemSettings,
                sendTestEnabled: false
            )
        case .provisional:
            return DesktopNotificationPermissionPresentation(
                statusLabel: .deliverQuietly,
                subtitle: .allowed,
                primaryAction: .openSystemSettings,
                sendTestEnabled: true
            )
        case .ephemeral:
            return DesktopNotificationPermissionPresentation(
                statusLabel: .temporary,
                subtitle: .allowed,
                primaryAction: .openSystemSettings,
                sendTestEnabled: true
            )
        }
    }

    var statusText: String {
        switch statusLabel {
        case .unknown:
            return String(localized: "settings.notifications.desktop.status.unknown", defaultValue: "Permission unknown")
        case .notRequested:
            return String(localized: "settings.notifications.desktop.status.notRequested", defaultValue: "Not Requested")
        case .allowed:
            return String(localized: "settings.notifications.desktop.status.allowed", defaultValue: "Allowed")
        case .denied:
            return String(localized: "settings.notifications.desktop.status.denied", defaultValue: "Denied")
        case .deliverQuietly:
            return String(localized: "settings.notifications.desktop.status.deliverQuietly", defaultValue: "Deliver Quietly")
        case .temporary:
            return String(localized: "settings.notifications.desktop.status.temporary", defaultValue: "Temporary")
        }
    }

    var subtitleText: String {
        switch subtitle {
        case .notDetermined:
            return String(localized: "settings.notifications.desktop.subtitle.notDetermined", defaultValue: "Desktop notifications are not enabled yet.")
        case .allowed:
            return String(localized: "settings.notifications.desktop.subtitle.allowed", defaultValue: "Desktop notifications are enabled.")
        case .denied:
            return String(localized: "settings.notifications.desktop.subtitle.denied", defaultValue: "Desktop notifications are disabled in System Settings.")
        }
    }

    var primaryActionTitle: String? {
        guard let primaryAction else { return nil }
        switch primaryAction {
        case .requestAuthorization:
            return String(localized: "settings.notifications.desktop.action.enable", defaultValue: "Enable")
        case .openSystemSettings:
            return String(localized: "settings.notifications.desktop.action.openSettings", defaultValue: "Open System Settings")
        }
    }
}

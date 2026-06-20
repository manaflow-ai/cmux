import Foundation

enum LocalizedTextValue: Equatable, Sendable {
    case desktopNotificationStatusChecking
    case desktopNotificationStatusNotDetermined
    case desktopNotificationStatusAllowed
    case desktopNotificationStatusDenied
    case desktopNotificationStatusProvisional
    case desktopNotificationStatusEphemeral
    case desktopNotificationSubtitleChecking
    case desktopNotificationSubtitleNotDetermined
    case desktopNotificationSubtitleAllowed
    case desktopNotificationSubtitleDenied
    case desktopNotificationSubtitleProvisional
    case desktopNotificationSubtitleEphemeral
    case desktopNotificationActionEnable
    case desktopNotificationActionOpenSystemSettings
    case desktopNotificationActionSendTest

    var key: String {
        switch self {
        case .desktopNotificationStatusChecking:
            "settings.notifications.desktop.status.checking"
        case .desktopNotificationStatusNotDetermined:
            "settings.notifications.desktop.status.notDetermined"
        case .desktopNotificationStatusAllowed:
            "settings.notifications.desktop.status.allowed"
        case .desktopNotificationStatusDenied:
            "settings.notifications.desktop.status.denied"
        case .desktopNotificationStatusProvisional:
            "settings.notifications.desktop.status.provisional"
        case .desktopNotificationStatusEphemeral:
            "settings.notifications.desktop.status.ephemeral"
        case .desktopNotificationSubtitleChecking:
            "settings.notifications.desktop.subtitle.checking"
        case .desktopNotificationSubtitleNotDetermined:
            "settings.notifications.desktop.subtitle.notDetermined"
        case .desktopNotificationSubtitleAllowed:
            "settings.notifications.desktop.subtitle.allowed"
        case .desktopNotificationSubtitleDenied:
            "settings.notifications.desktop.subtitle.denied"
        case .desktopNotificationSubtitleProvisional:
            "settings.notifications.desktop.subtitle.provisional"
        case .desktopNotificationSubtitleEphemeral:
            "settings.notifications.desktop.subtitle.ephemeral"
        case .desktopNotificationActionEnable:
            "settings.notifications.desktop.action.enable"
        case .desktopNotificationActionOpenSystemSettings:
            "settings.notifications.desktop.action.openSystemSettings"
        case .desktopNotificationActionSendTest:
            "settings.notifications.desktop.sendTest"
        }
    }

    var localizedString: String {
        switch self {
        case .desktopNotificationStatusChecking:
            String(localized: "settings.notifications.desktop.status.checking", defaultValue: "Checking...")
        case .desktopNotificationStatusNotDetermined:
            String(localized: "settings.notifications.desktop.status.notDetermined", defaultValue: "Not requested")
        case .desktopNotificationStatusAllowed:
            String(localized: "settings.notifications.desktop.status.allowed", defaultValue: "Allowed")
        case .desktopNotificationStatusDenied:
            String(localized: "settings.notifications.desktop.status.denied", defaultValue: "Denied")
        case .desktopNotificationStatusProvisional:
            String(localized: "settings.notifications.desktop.status.provisional", defaultValue: "Deliver Quietly")
        case .desktopNotificationStatusEphemeral:
            String(localized: "settings.notifications.desktop.status.ephemeral", defaultValue: "Temporary")
        case .desktopNotificationSubtitleChecking:
            String(localized: "settings.notifications.desktop.subtitle.checking", defaultValue: "Checking notification permission.")
        case .desktopNotificationSubtitleNotDetermined:
            String(localized: "settings.notifications.desktop.subtitle.notDetermined", defaultValue: "Desktop notifications are not enabled yet.")
        case .desktopNotificationSubtitleAllowed:
            String(localized: "settings.notifications.desktop.subtitle.allowed", defaultValue: "Desktop notifications are enabled.")
        case .desktopNotificationSubtitleDenied:
            String(localized: "settings.notifications.desktop.subtitle.denied", defaultValue: "Enable notifications for cmux in System Settings.")
        case .desktopNotificationSubtitleProvisional:
            String(localized: "settings.notifications.desktop.subtitle.provisional", defaultValue: "Desktop notifications are enabled quietly.")
        case .desktopNotificationSubtitleEphemeral:
            String(localized: "settings.notifications.desktop.subtitle.ephemeral", defaultValue: "Desktop notification permission is temporary.")
        case .desktopNotificationActionEnable:
            String(localized: "settings.notifications.desktop.action.enable", defaultValue: "Enable")
        case .desktopNotificationActionOpenSystemSettings:
            String(localized: "settings.notifications.desktop.action.openSystemSettings", defaultValue: "Open System Settings")
        case .desktopNotificationActionSendTest:
            String(localized: "settings.notifications.desktop.sendTest", defaultValue: "Send Test")
        }
    }
}

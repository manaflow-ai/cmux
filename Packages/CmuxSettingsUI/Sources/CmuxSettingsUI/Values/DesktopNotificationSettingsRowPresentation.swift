import CmuxSettings
import Foundation

struct DesktopNotificationSettingsRowPresentation: Equatable, Sendable {
    let authorizationState: DesktopNotificationAuthorizationState

    init(authorizationState: DesktopNotificationAuthorizationState) {
        self.authorizationState = authorizationState
    }

    var status: LocalizedTextValue {
        switch authorizationState {
        case .unknown:
            .desktopNotificationStatusChecking
        case .notDetermined:
            .desktopNotificationStatusNotDetermined
        case .authorized:
            .desktopNotificationStatusAllowed
        case .denied:
            .desktopNotificationStatusDenied
        case .provisional:
            .desktopNotificationStatusProvisional
        case .ephemeral:
            .desktopNotificationStatusEphemeral
        }
    }

    var subtitle: LocalizedTextValue {
        switch authorizationState {
        case .unknown:
            .desktopNotificationSubtitleChecking
        case .notDetermined:
            .desktopNotificationSubtitleNotDetermined
        case .authorized:
            .desktopNotificationSubtitleAllowed
        case .denied:
            .desktopNotificationSubtitleDenied
        case .provisional:
            .desktopNotificationSubtitleProvisional
        case .ephemeral:
            .desktopNotificationSubtitleEphemeral
        }
    }

    var primaryAction: DesktopNotificationPrimaryAction {
        switch authorizationState {
        case .unknown, .notDetermined:
            .requestAuthorization
        case .authorized, .denied, .provisional, .ephemeral:
            .openSystemSettings
        }
    }

    var primaryActionTitle: LocalizedTextValue {
        switch primaryAction {
        case .requestAuthorization:
            .desktopNotificationActionEnable
        case .openSystemSettings:
            .desktopNotificationActionOpenSystemSettings
        }
    }
}

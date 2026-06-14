import CmuxSettings
import Foundation

@MainActor
struct DesktopNotificationSettingsRowActions {
    let hostActions: SettingsHostActions

    func performPrimaryAction(
        for authorizationState: DesktopNotificationAuthorizationState
    ) async -> DesktopNotificationAuthorizationState {
        let presentation = DesktopNotificationSettingsRowPresentation(
            authorizationState: authorizationState
        )
        guard let primaryAction = presentation.primaryAction else {
            return authorizationState
        }
        switch primaryAction {
        case .requestAuthorization:
            return await hostActions.requestNotificationAuthorization()
        case .openSystemSettings:
            hostActions.openSystemNotificationSettings()
            return await hostActions.refreshDesktopNotificationAuthorizationState()
        case .sendTest:
            hostActions.sendTestNotification()
            return authorizationState
        }
    }
}

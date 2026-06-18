import CmuxSettings
import Foundation

@MainActor
struct DesktopNotificationSettingsRowActions {
    let hostActions: SettingsHostActions

    func performPrimaryAction(
        for authorizationState: DesktopNotificationAuthorizationState
    ) async {
        let presentation = DesktopNotificationSettingsRowPresentation(
            authorizationState: authorizationState
        )
        guard let primaryAction = presentation.primaryAction else {
            return
        }
        switch primaryAction {
        case .requestAuthorization:
            _ = await hostActions.requestNotificationAuthorization()
        case .openSystemSettings:
            hostActions.openSystemNotificationSettings()
            _ = await hostActions.refreshDesktopNotificationAuthorizationState()
        case .sendTest:
            hostActions.sendTestNotification()
        }
    }
}

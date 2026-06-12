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
        switch presentation.primaryAction {
        case .requestAuthorization:
            return await hostActions.requestNotificationAuthorization()
        case .openSystemSettings:
            hostActions.openSystemNotificationSettings()
            return await hostActions.refreshDesktopNotificationAuthorizationState()
        }
    }
}

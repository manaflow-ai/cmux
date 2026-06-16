import CmuxSettings
@testable import CmuxSettingsUI

@MainActor
final class RecordingSettingsHostActions: SettingsHostActions {
    private var state: DesktopNotificationAuthorizationState
    private let refreshedState: DesktopNotificationAuthorizationState

    private(set) var requestAuthorizationCallCount = 0
    private(set) var sendTestNotificationCallCount = 0
    private(set) var openSystemSettingsCallCount = 0
    private(set) var refreshCallCount = 0

    init(
        state: DesktopNotificationAuthorizationState,
        refreshedState: DesktopNotificationAuthorizationState
    ) {
        self.state = state
        self.refreshedState = refreshedState
    }

    func clearBrowserHistory() {}
    func openConfigInExternalEditor() {}
    func sendFeedback() {}
    func sendTestNotification() {
        sendTestNotificationCallCount += 1
    }

    func openSystemNotificationSettings() {
        openSystemSettingsCallCount += 1
    }

    func restartApp() {}
    func openBrowserImportFlow() {}

    func desktopNotificationAuthorizationState() -> DesktopNotificationAuthorizationState {
        state
    }

    func refreshDesktopNotificationAuthorizationState() async -> DesktopNotificationAuthorizationState {
        refreshCallCount += 1
        state = refreshedState
        return state
    }

    func requestNotificationAuthorization() async -> DesktopNotificationAuthorizationState {
        requestAuthorizationCallCount += 1
        state = refreshedState
        return state
    }

    func openTerminalConfigWindow() {}
    func openMobilePairingWindow() {}
    func previewNotificationSound(value: String, customFilePath: String) {}
}

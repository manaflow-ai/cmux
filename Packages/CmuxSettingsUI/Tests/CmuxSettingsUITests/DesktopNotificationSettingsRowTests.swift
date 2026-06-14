import CmuxSettings
import Testing
@testable import CmuxSettingsUI

@Suite("DesktopNotificationSettingsRow")
struct DesktopNotificationSettingsRowTests {
    @Test @MainActor func notDeterminedRequestsAuthorization() async {
        let host = RecordingSettingsHostActions(state: .notDetermined, refreshedState: .authorized)
        let result = await DesktopNotificationSettingsRowActions(hostActions: host)
            .performPrimaryAction(for: .notDetermined)

        #expect(host.requestAuthorizationCallCount == 1)
        #expect(host.openSystemSettingsCallCount == 0)
        #expect(host.refreshCallCount == 0)
        #expect(result == .authorized)
    }

    @Test @MainActor func deniedOpensSystemSettingsAndRefreshes() async {
        let host = RecordingSettingsHostActions(state: .denied, refreshedState: .denied)
        let result = await DesktopNotificationSettingsRowActions(hostActions: host)
            .performPrimaryAction(for: .denied)

        #expect(host.requestAuthorizationCallCount == 0)
        #expect(host.openSystemSettingsCallCount == 1)
        #expect(host.refreshCallCount == 1)
        #expect(result == .denied)
    }

    @Test(arguments: [
        DesktopNotificationAuthorizationState.authorized,
        .provisional,
        .ephemeral,
    ])
    @MainActor func allowedStatesSendTestNotification(state: DesktopNotificationAuthorizationState) async {
        let host = RecordingSettingsHostActions(state: state, refreshedState: state)
        let result = await DesktopNotificationSettingsRowActions(hostActions: host)
            .performPrimaryAction(for: state)

        #expect(host.requestAuthorizationCallCount == 0)
        #expect(host.openSystemSettingsCallCount == 0)
        #expect(host.refreshCallCount == 0)
        #expect(host.sendTestNotificationCallCount == 1)
        #expect(result == state)
    }

    @Test @MainActor func unknownDoesNotTriggerLiveAction() async {
        let host = RecordingSettingsHostActions(state: .unknown, refreshedState: .denied)
        let result = await DesktopNotificationSettingsRowActions(hostActions: host)
            .performPrimaryAction(for: .unknown)

        #expect(host.requestAuthorizationCallCount == 0)
        #expect(host.openSystemSettingsCallCount == 0)
        #expect(host.refreshCallCount == 0)
        #expect(host.sendTestNotificationCallCount == 0)
        #expect(result == .unknown)
    }

    @Test(arguments: [
        (
            DesktopNotificationAuthorizationState.unknown,
            "settings.notifications.desktop.status.checking",
            "settings.notifications.desktop.subtitle.checking",
            nil
        ),
        (
            .notDetermined,
            "settings.notifications.desktop.status.notDetermined",
            "settings.notifications.desktop.subtitle.notDetermined",
            .requestAuthorization
        ),
        (
            .authorized,
            "settings.notifications.desktop.status.allowed",
            "settings.notifications.desktop.subtitle.allowed",
            .sendTest
        ),
        (
            .denied,
            "settings.notifications.desktop.status.denied",
            "settings.notifications.desktop.subtitle.denied",
            .openSystemSettings
        ),
        (
            .provisional,
            "settings.notifications.desktop.status.provisional",
            "settings.notifications.desktop.subtitle.provisional",
            .sendTest
        ),
        (
            .ephemeral,
            "settings.notifications.desktop.status.ephemeral",
            "settings.notifications.desktop.subtitle.ephemeral",
            .sendTest
        ),
    ])
    func presentationMapsAuthorizationState(
        state: DesktopNotificationAuthorizationState,
        statusKey: String,
        subtitleKey: String,
        primaryAction: DesktopNotificationPrimaryAction?
    ) {
        let presentation = DesktopNotificationSettingsRowPresentation(authorizationState: state)

        #expect(presentation.status.key == statusKey)
        #expect(presentation.subtitle.key == subtitleKey)
        #expect(presentation.primaryAction == primaryAction)
    }
}

private final class RecordingSettingsHostActions: SettingsHostActions {
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

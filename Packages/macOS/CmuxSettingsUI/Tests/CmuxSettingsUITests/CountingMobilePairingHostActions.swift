import Foundation

@testable import CmuxSettingsUI

@MainActor
final class CountingMobilePairingHostActions: SettingsHostActions {
    var statusReads = 0
    var streamCreations = 0
    var desktopStatusReads = 0
    var desktopStreamCreations = 0
    var desktopRefreshes = 0
    var desktopStatus: DesktopNotificationAuthorizationState = .unknown

    private let stream: AsyncStream<MobilePairingStatusSnapshot>
    private let desktopStream: AsyncStream<DesktopNotificationAuthorizationState>

    init(
        stream: AsyncStream<MobilePairingStatusSnapshot>,
        desktopStream: AsyncStream<DesktopNotificationAuthorizationState> = AsyncStream { $0.finish() }
    ) {
        self.stream = stream
        self.desktopStream = desktopStream
    }

    func clearBrowserHistory() {}
    func openConfigInExternalEditor() {}
    func sendFeedback() {}
    func sendTestNotification() {}
    func openSystemNotificationSettings() {}
    func restartApp() {}
    func openBrowserImportFlow() {}
    func requestNotificationAuthorization() {}
    func openTerminalConfigWindow() {}
    func previewNotificationSound(value: String, customFilePath: String) {}

    func mobilePairingStatus() -> MobilePairingStatusSnapshot? {
        statusReads += 1
        return nil
    }

    func mobilePairingStatusUpdates() -> AsyncStream<MobilePairingStatusSnapshot> {
        streamCreations += 1
        return stream
    }

    func desktopNotificationAuthorizationStatus() -> DesktopNotificationAuthorizationState {
        desktopStatusReads += 1
        return desktopStatus
    }

    func desktopNotificationAuthorizationStatusUpdates() -> AsyncStream<DesktopNotificationAuthorizationState> {
        desktopStreamCreations += 1
        return desktopStream
    }

    func refreshDesktopNotificationAuthorizationStatus() {
        desktopRefreshes += 1
    }
}

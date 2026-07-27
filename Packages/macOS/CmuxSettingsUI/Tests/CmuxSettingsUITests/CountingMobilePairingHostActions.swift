import Foundation

@testable import CmuxSettingsUI

@MainActor
final class CountingMobilePairingHostActions: SettingsHostActions {
    var statusReads = 0
    var streamCreations = 0

    private let stream: AsyncStream<MobilePairingStatusSnapshot>

    init(stream: AsyncStream<MobilePairingStatusSnapshot>) {
        self.stream = stream
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
}

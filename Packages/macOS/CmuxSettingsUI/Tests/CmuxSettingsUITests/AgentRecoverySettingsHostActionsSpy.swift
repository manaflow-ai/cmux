import CmuxSettings
import Foundation

@testable import CmuxSettingsUI

@MainActor
final class AgentRecoverySettingsHostActionsSpy: SettingsHostActions {
    private(set) var autoRetryChangeCount = 0
    private var autoRetryChangeWaiters: [CheckedContinuation<Void, Never>] = []

    func agentSessionAutoRetrySettingDidChange() {
        autoRetryChangeCount += 1
        let waiters = autoRetryChangeWaiters
        autoRetryChangeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForAutoRetryChange() async {
        guard autoRetryChangeCount == 0 else { return }
        await withCheckedContinuation { continuation in
            autoRetryChangeWaiters.append(continuation)
        }
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
}

import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite("Agent recovery settings")
struct AgentRecoverySettingsModelTests {
    @Test("auto-retry publishes its live signal only after persistence commits")
    func autoRetrySignalsCommittedChange() async {
        let suiteName = "AgentRecoverySettingsModelTests.\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!
        )
        let host = AgentRecoverySettingsHostActionsSpy()
        let model = AgentRecoverySettingsModel(
            defaultsStore: store,
            catalog: SettingCatalog(),
            hostActions: host
        )

        #expect(!model.isAutoRetryEnabled)
        model.setAutoRetryEnabled(true)
        await host.waitForAutoRetryChange()

        #expect(host.autoRetryChangeCount == 1)
        #expect(await store.value(for: SettingCatalog().terminal.autoRetryAgentSessions))
    }
}

@MainActor
private final class AgentRecoverySettingsHostActionsSpy: SettingsHostActions {
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

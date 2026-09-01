import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite("Agent recovery settings")
struct AgentRecoverySettingsModelTests {
    @Test("auto-retry publishes its live signal only after persistence commits")
    func autoRetrySignalsCommittedChange() async throws {
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
        try await host.waitForAutoRetryChange()

        #expect(host.autoRetryChangeCount == 1)
        #expect(await store.value(for: SettingCatalog().terminal.autoRetryAgentSessions))
    }
}

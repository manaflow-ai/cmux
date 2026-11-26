@testable import CmuxNextAgentIntegrations
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// #54632 without observation: the app's wiring (the real process runner on a script CLI), one
/// refresh through `PageProvider`, then the rows. The crash was in that refresh's resume.
@MainActor struct SettingsAgentIntegrationsRunnerTests {
    @Test func refreshThroughTheAppsRunnerReadsTheRows() async throws {
        let cli = try SettingsAgentIntegrationsExecutorTests.scriptCLI()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let model = SettingsAgentIntegrations(cli: { cli })
        let provider: any PageProvider = model
        _ = try await provider.call("cmux.settings.integrations.run", params: ["action": "refresh"],
                                    context: SettingsAgentIntegrationsTests.script)
        MainActor.assertIsolated("refresh resumed off the main actor")
        #expect(model.state["providers"]?.arrayValue?.count == 5)
        #expect(model.state["problem"] == .null)
    }
}

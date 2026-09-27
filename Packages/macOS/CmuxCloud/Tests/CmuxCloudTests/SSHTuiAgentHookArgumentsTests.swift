import CmuxCloud
import CmuxCore
import Foundation
import Testing

@Suite("SSH cmux-tui agent hook arguments")
struct SSHTuiAgentHookArgumentsTests {
    private func connection() -> SSHTuiConnection {
        SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            terminalProfile: .shell, destination: "alice@example.invalid", port: 2222, identityFile: nil,
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: nil,
            preserveAfterTerminalExit: true
        ))
    }

    @Test("The carrier asks the host to install the requested hooks")
    func carrierRequestsAgentHooks() throws {
        var carrier = connection()
        let plain = carrier.arguments(stateDirectory: "/tmp/state", deviceName: "test")
        #expect(!plain.contains("--agent-hooks"))
        carrier.agentHookProviders = ["claude", "codex"]
        let arguments = carrier.arguments(stateDirectory: "/tmp/state", deviceName: "test")
        let index = try #require(arguments.firstIndex(of: "--agent-hooks"))
        #expect(arguments[index + 1] == "claude,codex")
        #expect(carrier.id == connection().id)
    }

    @Test("Integrations toggles choose the providers")
    func providersFollowIntegrationToggles() throws {
        let suite = "SSHTuiAgentHookArgumentsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SSHTuiConnection.agentHookProviders(defaults: defaults) == ["claude", "codex"])
        defaults.set(false, forKey: "claudeCodeHooksEnabled")
        #expect(SSHTuiConnection.agentHookProviders(defaults: defaults) == ["codex"])
        defaults.set(false, forKey: "codexHooksEnabled")
        #expect(SSHTuiConnection.agentHookProviders(defaults: defaults).isEmpty)
    }
}

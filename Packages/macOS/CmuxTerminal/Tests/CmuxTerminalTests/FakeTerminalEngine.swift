import GhosttyKit
@testable import CmuxTerminal

@MainActor
final class FakeTerminalEngine: TerminalEngineHosting {
    private(set) var runtimeAppAccessCount = 0
    private(set) var runtimeConfigAccessCount = 0

    var runtimeApp: ghostty_app_t? {
        runtimeAppAccessCount += 1
        return nil
    }
    var runtimeConfig: ghostty_config_t? {
        runtimeConfigAccessCount += 1
        return nil
    }
    var userGhosttyShellIntegrationMode: String { "none" }
}

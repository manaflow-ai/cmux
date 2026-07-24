import GhosttyKit
@testable import CmuxTerminal

@MainActor
final class FakeTerminalEngine: TerminalEngineHosting {
    init(runtimeConfig: ghostty_config_t? = nil) {
        self.runtimeConfig = runtimeConfig
    }

    var runtimeApp: ghostty_app_t? { nil }
    var runtimeConfig: ghostty_config_t?
    var userGhosttyShellIntegrationMode: String { "none" }
    var hasUserGhosttyCommand: Bool { false }
    var resolvedUserShell: String? { nil }
}

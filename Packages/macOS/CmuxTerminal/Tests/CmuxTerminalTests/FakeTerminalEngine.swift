import GhosttyKit
@testable import CmuxTerminal

@MainActor
final class FakeTerminalEngine: TerminalEngineHosting {
    var runtimeApp: ghostty_app_t? { nil }
    var runtimeConfig: ghostty_config_t? { nil }
    var userGhosttyShellIntegrationMode: String { "none" }
}

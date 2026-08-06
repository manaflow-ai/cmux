import GhosttyKit
@testable import CmuxTerminal

@MainActor
final class FakeTerminalEngine: TerminalEngineHosting {
    var runtimeApp: ghostty_app_t? { nil }
    var runtimeConfig: ghostty_config_t? { nil }
    var userGhosttyShellIntegrationMode: String { "none" }
    var hasUserGhosttyCommand: Bool { false }
    var resolvedUserShell: String? { nil }
    var terminalFontConfigurationGeneration: UInt64 = 0
    var terminalFontConfigurationRuntimePoints: Float32 = 12
    var shouldDeferRuntimeSurfaceCreationForConfigurationReload =
        false
    private(set) var deferredRuntimeSurfaceCreationActions:
        [@MainActor () -> Void] = []

    func deferRuntimeSurfaceCreationForConfigurationReload(
        _ action: @escaping @MainActor () -> Void
    ) -> Bool {
        guard shouldDeferRuntimeSurfaceCreationForConfigurationReload else {
            return false
        }
        deferredRuntimeSurfaceCreationActions.append(action)
        return true
    }

    func runNextDeferredRuntimeSurfaceCreation() {
        deferredRuntimeSurfaceCreationActions.removeFirst()()
    }
}

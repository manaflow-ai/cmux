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

public import GhosttyKit

/// Read access to the embedded Ghostty engine the surface model spawns
/// against.
///
/// Implemented by the app's engine owner (`GhosttyApp`, later
/// `GhosttyAppService`); the surface model never names the concrete engine.
@MainActor
public protocol TerminalEngineHosting: AnyObject {
    /// The live runtime app handle, or nil before engine initialization.
    var runtimeApp: ghostty_app_t? { get }

    /// The live runtime config handle, or nil before the first config load.
    var runtimeConfig: ghostty_config_t? { get }

    /// The user's effective `shell-integration` Ghostty config value
    /// (`"detect"`, `"none"`, or an explicit shell).
    var userGhosttyShellIntegrationMode: String { get }

    /// Whether Ghostty's app configuration supplies the default surface command.
    var hasUserGhosttyCommand: Bool { get }

    /// The executable user shell resolved before Ghostty config finalization.
    var resolvedUserShell: String? { get }

    /// Monotonic generation of the terminal font configuration currently
    /// applied to the runtime.
    var terminalFontConfigurationGeneration: UInt64 { get }

    /// Current configured runtime font size, including global magnification.
    var terminalFontConfigurationRuntimePoints: Float32 { get }

    /// Defers native surface creation until an in-flight engine configuration
    /// reload has applied its replacement config.
    ///
    /// - Returns: True when `action` was accepted for deferred execution.
    func deferRuntimeSurfaceCreationForConfigurationReload(
        _ action: @escaping @MainActor () -> Void
    ) -> Bool
}

/// Default behavior for engine hosts without a configuration-reload barrier.
public extension TerminalEngineHosting {
    /// Runs immediately when the engine does not provide a reload barrier.
    ///
    /// Concrete engine owners override this default to defer creation while a
    /// replacement runtime configuration is being committed.
    ///
    /// - Returns: Always `false`, indicating that `action` was not deferred.
    func deferRuntimeSurfaceCreationForConfigurationReload(
        _ action: @escaping @MainActor () -> Void
    ) -> Bool {
        false
    }
}

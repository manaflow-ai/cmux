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
}

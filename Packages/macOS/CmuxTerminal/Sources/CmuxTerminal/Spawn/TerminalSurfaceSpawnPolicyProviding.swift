public import Foundation

/// Live settings and control-plane reads the surface model performs while
/// assembling a spawn.
///
/// Implemented in the app over the settings stores and
/// `TerminalController`'s socket bookkeeping. Every method is a synchronous
/// main-actor read so spawn assembly observes the same values, at the same
/// instant, as the legacy inline reads it replaces.
@MainActor
public protocol TerminalSurfaceSpawnPolicyProviding: AnyObject {
    /// The settings snapshot folded into the spawned environment.
    func currentSpawnPolicy() -> TerminalSurfaceSpawnPolicy

    /// The active control socket path exported as `CMUX_SOCKET_PATH`.
    func controlSocketPath() -> String

    /// Adds the secrets a startup command reads from its environment rather
    /// than its arguments, such as a workspace's SSH foreground-auth token.
    ///
    /// Runs after the surface's initial environment overrides are merged, so
    /// it also replaces a secret those overrides still carry from an earlier
    /// launch.
    ///
    /// - Parameters:
    ///   - environment: Environment the surface is about to spawn with.
    ///   - workspaceId: Workspace that owns the surface.
    ///   - startupCommand: Command the surface is about to run, if any.
    func applyStartupCommandSecrets(
        to environment: inout [String: String],
        workspaceId: UUID,
        startupCommand: String?
    )
}

extension TerminalSurfaceSpawnPolicyProviding {
    public func applyStartupCommandSecrets(
        to environment: inout [String: String],
        workspaceId: UUID,
        startupCommand: String?
    ) {}
}

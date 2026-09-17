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
}

import Foundation

/// App-owned blocking policy seam for terminal runtime spawns.
@MainActor
public protocol TerminalSurfaceSpawnGating: AnyObject {
    /// Returns whether a blocking gate is configured for the next spawn.
    func requiresGate() -> Bool

    /// Resolves one pending terminal spawn.
    /// - Parameter request: The pending spawn request.
    /// - Returns: A proceed grant or a denial.
    func resolveSpawn(_ request: TerminalSurfaceSpawnGateRequest) async -> TerminalSurfaceSpawnGateResolution

    /// Builds the localized message rendered into a denied terminal surface.
    /// - Parameter reason: The denial reason.
    /// - Returns: User-facing denial text.
    func deniedSpawnMessage(reason: String) -> String

    /// Performs app-owned side effects for a denied spawn.
    /// - Parameters:
    ///   - reason: The denial reason.
    ///   - request: The denied spawn request.
    func spawnDenied(reason: String, request: TerminalSurfaceSpawnGateRequest)
}

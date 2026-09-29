public import Foundation

/// Identifies one native-runtime lifetime for a `TerminalSurface`: the
/// surface model's stable id, paired with the `runtimeSurfaceGeneration`
/// that was current when a particular `ghostty_surface_t` was installed.
///
/// A bare `TerminalSurface.id` is NOT a safe key for lease/teardown/cache
/// state: agent hibernation frees the native runtime while keeping the
/// model alive (`suspendRuntimeSurfaceForAgentHibernation`), and a later
/// resume (`prepareAgentHibernationResume`) installs a NEW runtime under
/// the SAME id, bumping `runtimeSurfaceGeneration`. State keyed by id alone
/// would either leak forever (if never cleared) or let a stale, delayed
/// operation from the OLD runtime silently apply against the NEW one (if
/// cleared and reused). Keying by this pair instead makes each native
/// runtime's lifetime independently identifiable and independently
/// tombstone-able.
public struct RuntimeSurfaceLifetimeID: Hashable, Sendable {
    public let surfaceID: UUID
    /// The `runtimeSurfaceGeneration` that was current while the native
    /// pointer this lifetime tracks was installed — captured by the
    /// teardown caller BEFORE `TerminalSurface.surface = nil` advances it,
    /// so this always names the lifetime that is actually ending.
    public let runtimeSurfaceGeneration: UInt64

    public init(surfaceID: UUID, runtimeSurfaceGeneration: UInt64) {
        self.surfaceID = surfaceID
        self.runtimeSurfaceGeneration = runtimeSurfaceGeneration
    }
}

import Foundation

/// Actor-owned coalescing state for ``GhosttyPointerStyleIngress``.
struct GhosttyPointerStyleIngressPendingState: Sendable {
    var activeRuntimeLifetimeId: UUID?
    var activeRuntimeGeneration: UInt64 = 0
    var retiredRuntimeLifetimeIds: Set<UUID> = []
    /// Last lifecycle sequence applied for each runtime, retained across
    /// drains so delayed pre-reset pointer events cannot be reintroduced.
    var lifecycleCutoffByRuntime: [UUID: UInt64] = [:]
    var byRuntime: [UUID: GhosttyPointerStyleIngressRuntimePending] = [:]
    var drainScheduled = false
}

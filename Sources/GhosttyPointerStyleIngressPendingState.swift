import Foundation

/// Actor-owned coalescing state for ``GhosttyPointerStyleIngress``.
struct GhosttyPointerStyleIngressPendingState: Sendable {
    var activeRuntimeLifetimeId: UUID?
    var activeRuntimeGeneration: UInt64 = 0
    var retiredRuntimeLifetimeIds: Set<UUID> = []
    var byRuntime: [UUID: GhosttyPointerStyleIngressRuntimePending] = [:]
    var drainScheduled = false
}
